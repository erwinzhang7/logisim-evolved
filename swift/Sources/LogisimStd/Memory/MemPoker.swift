// MemPoker.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.MemPoker),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── UI seam ──────────────────────────────────────────────────────────────────────────────────
//
// Upstream's `MemPoker extends InstancePoker`, an AWT-facing base class (`KeyEvent`/
// `MouseEvent`/`Graphics`) that has not been ported; `InstanceFactory.swift`'s header notes
// pokers are deferred to M6 as "closures or protocol witnesses". This file does not wait for
// that: it ports the *model*, hit-testing (which address a click landed on), the edit state
// machine (which cell is being typed into, and with what value so far), and every scroll/cursor
// math the two upstream `keyTyped`/`keyPressed` overrides perform, behind three small,
// AppKit-free input types (`MemPokerNavigationKey`, and plain `Character`/`Bool` for typed
// keys). Whatever M6 UI type eventually represents "the poke tool is active over this
// component" is expected to:
//
//   1. translate its raw mouse-down into a `Location` and call `begin(at:state:)`;
//   2. translate `NSEvent.keyCode`/`.charactersIgnoringModifiers` into `MemPokerNavigationKey` /
//      `(Character, control: Bool)` and call `keyPressed`/`keyTyped`;
//   3. read `highlightBounds(_:)` each redraw and stroke it (upstream draws a red-then-black
//      rectangle: a fixed two-color outline, not a real style choice, so the renderer is free
//      to pick whatever stroke reads as "editing here" as long as it is not invisible).
//
// Upstream's `RomAttributes.setProject(proj)` call inside `DataPoker`'s constructor (wiring the
// ROM's attribute set to the current `Project` so its hex-editor menu item works) is UI/editing
// -session plumbing, not edit logic, and is dropped; the M6/M7 owner of `RomAttributes` should
// do that wiring at the tool level instead of inside the poker.
//
// ── Two upstream bugs, preserved ────────────────────────────────────────────────────────────
//
//   * `AddrPoker.keyTyped`'s space bar: the `Ctrl+Space` and plain-`Space` branches compute the
//     *same* expression (`scroll + (nrOfLines - 1) * nrOfLineItems`); Ctrl has no distinguishing
//     effect here, unlike every other navigation key in this file. Almost certainly a copy-paste
//     slip in upstream (compare `DataPoker`'s space handler, where the two branches differ); kept
//     exactly, since "fixing" it changes what a saved `.circ` produces when replayed.
//   * `AddrPoker.keyPressed`'s left/right arrows move the scroll by a full `nrOfLineItems`, the
//     same distance as up/down: not by one item, which is what "left/right" would suggest.
//     Preserved for the same reason.
//
// ── API from `MemState`/`MemContents` (owned by the Mem/Ram/Rom slice, landed) ──────────────
//
// `MemState.swift` landed, while this file was already written against a guessed API, with a
// different shape than guessed: `getContents()`/`getCursor()`/`setCursor(_:)`/`getScroll()`/
// `setScroll(_:)`/`getLastAddress()` are *methods*, not computed properties, and `nrOfLines`/
// `nrDataSymbolsEachLine`/`contents` are plain `internal` stored fields (accessible directly,
// same module) rather than a `nrOfLineItems`-named accessor. Every call site below is written
// against the real, landed names.
//
// `getAddressAt(int,int)` / `getBounds(long,Bounds)` / `getDataBounds(long,Bounds)` are a
// different story: `MemState.swift`'s own header defers *all* paint-derived geometry to M6 (the
// fields `calculateDisplayParameters`, never called without a `Graphics` context, would
// populate: `addrBlockSize`, `dataBlockSize`, `dataSize`, `xOffset`, `yOffset`, `charHeight`) and
// does not implement these three at all. `MemPoker` cannot skip them the same way, hit-testing a
// click *is* this poker's job, so they are implemented below as an extension on `MemState`
// (`addressAt`/`bounds(forAddress:in:)`/`dataBounds(forAddress:in:)`), reading those same
// `internal` fields directly rather than duplicating them. Since those fields are never populated
// without a paint pass, every one of these three is a guaranteed no-op (`-1` / `.empty`) exactly
// like `MemState.scrollToShow`/`setScroll` already are: real code, dead until M6, not a shortcut.
// Flagged in the final report: once M6 implements `calculateDisplayParameters`, this extension's
// logic is a natural fit to fold into `MemState.swift` itself, since it reads the same fields
// that method populates.
//
//   `MemContents.get(_ address: Int64) -> Int64`
//   `MemContents.set(_ address: Int64, _ value: Int64)`
//   `MemContents.clear()`

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// The six navigation keys upstream's `keyPressed` overrides distinguish. Everything else is
/// `default: {}` in Java, so there is nothing else to represent.
public enum MemPokerNavigationKey: Sendable {
  case up, down, left, right, pageUp, pageDown
}

// MARK: - `MemState` geometry — see the file header on why this lives here, not in `MemState.swift`.

// `getAddressAt(int, int)` used to live here too, but `DualRamState` **overrides** it, and Swift
// extension methods are statically dispatched; an override in a subclass would silently never
// be called. It now sits in `MemState`'s own class body (`MemState.swift`), which is where
// upstream declares it anyway.

extension MemState {
  /// `MemState.getBounds(long, Bounds)`; the address-column rectangle. `addr` is upstream's own
  /// dead parameter: `if (addr >= 0) addr -= curScroll;` reassigns the local and then never reads
  /// it again before the `return`. Preserved by simply not using the argument.
  func bounds(forAddress addr: Int64, in componentBounds: Bounds) -> Bounds {
    Bounds.create(
      componentBounds.x + xOffset, componentBounds.y + yOffset, addrBlockSize, charHeight + 2)
  }

  /// `MemState.getDataBounds(long, Bounds)`: the rectangle around one data cell, or `.empty`
  /// (upstream: `Bounds.EMPTY_BOUNDS`) if `addr` is not currently on screen.
  func dataBounds(forAddress addr: Int64, in componentBounds: Bounds) -> Bounds {
    var rowStart = curScroll
    for row in 0..<nrOfLines {
      for column in 0..<nrDataSymbolsEachLine {
        if rowStart + Int64(column) == addr, isValidAddr(rowStart + Int64(column)) {
          return dataBound(componentBounds.x, componentBounds.y, row: row, column: column)
        }
      }
      rowStart += Int64(nrDataSymbolsEachLine)
    }
    return .empty
  }

  /// `MemState.getDataBound(int, int, int, int)`. `internal`, not `private`: `MemState.paint`
  /// (M6) draws the current-address highlight with exactly this rectangle, and duplicating the
  /// arithmetic in a second file is how the two silently drift apart.
  func dataBound(_ xoff: Int, _ yoff: Int, row: Int, column: Int) -> Bounds {
    Bounds.create(
      xoff + firstXOffset + column * dataSize - (dataSize / 2) - 1,
      yoff + firstYOffset + row * dataBlockHeight - (charHeight / 2) - 1,
      dataBlockWidth, dataBlockHeight)
  }

  /// `MemState.getFirstXoffset()`.
  var firstXOffset: Int { xOffset + addrBlockSize + (spaceSize / 2) + ((dataSize - spaceSize) / 2) }
  /// `MemState.getFirstYoffset()`.
  var firstYOffset: Int { yOffset + (charHeight / 2) + 1 }
  /// `MemState.getDataBlockWidth()`.
  var dataBlockWidth: Int { dataSize + 2 }
  /// `MemState.getDataBlockHeight()`.
  var dataBlockHeight: Int { charHeight + 2 }
}

/// `com.cburch.logisim.std.memory.MemPoker`; the RAM/ROM cell editor's model half.
///
/// One instance is created per poke gesture (`begin(at:state:)` plays the role of upstream's
/// `init(InstanceState, MouseEvent)`, which upstream's tool framework calls once per mouse-down);
/// the same instance then receives every subsequent key event until the poke ends.
public final class MemPoker {

  /// The two upstream subclasses, `AddrPoker` and `DataPoker`, collapsed into one enum. Neither
  /// carries drawing state, so there is no `AbstractFlipFlop`-style inheritance to preserve.
  private enum Sub {
    /// `AddrPoker`: clicked outside the data grid, editing the scroll position.
    case address
    /// `DataPoker`, clicked a specific cell.
    case data(DataEdit)
  }

  private struct DataEdit {
    var cursor: Int64
    var currentValue: Int64
  }

  private var sub: Sub?

  public init() {}

  // MARK: Bounds (upstream `getBounds`)

  /// The rectangle to highlight around whatever is currently being edited, or `nil` before
  /// `begin(at:state:)` has run. Replaces upstream's `paint(InstancePainter)`; see the file
  /// header for the drawing seam.
  public func highlightBounds(_ state: any InstanceState) -> Bounds? {
    guard let data = state.data as? MemState else { return nil }
    return highlightBounds(data: data, componentBounds: state.component.bounds)
  }

  /// The same lookup from a paint context: `MemPoker.getBounds(InstancePainter)`, which
  /// upstream reaches through `sub.getBounds(state)`.
  public func highlightBounds(_ painter: any MemPainter) -> Bounds? {
    guard let data = painter.data as? MemState else { return nil }
    return highlightBounds(data: data, componentBounds: painter.bounds)
  }

  private func highlightBounds(data: MemState, componentBounds: Bounds) -> Bounds? {
    switch sub {
    case .none:
      return nil
    case .address:
      // `AddrPoker.getBounds`: `data.getBounds(-1, painter.getBounds())`.
      return data.bounds(forAddress: -1, in: componentBounds)
    case .data(let edit):
      // `DataPoker.getBounds`: `data.getDataBounds(cursor, instance.getBounds())`. Upstream's
      // `paint` additionally skips drawing when this comes back `Bounds.EMPTY_BOUNDS` (the
      // cursor scrolled out of view); the caller gets the same signal by treating an empty
      // result the same way it would treat `nil`.
      let bounds = data.dataBounds(forAddress: edit.cursor, in: componentBounds)
      return bounds == .empty ? nil : bounds
    }
  }

  // MARK: - Painting (M6)

  /// `MemPoker.paint(InstancePainter)` → `AddrPoker.paint` / `DataPoker.paint`
  /// (`MemPoker.java:88-98`, `:199-208`, `:249-252`): a red outline around the cell or the
  /// address column being edited.
  ///
  /// `AddrPoker.paint` does *not* have `DataPoker`'s empty-bounds guard, but its
  /// `getBounds` cannot return empty, so folding the two into one nil-check is exact.
  public func paint(_ painter: any MemPainter) {
    guard let bds = highlightBounds(painter) else { return }
    let g = painter.graphics
    g.color = MemPaint.red
    g.drawRect(bds.x, bds.y, bds.width, bds.height)
    g.color = MemPaint.black
  }

  // MARK: Starting a poke (upstream `init(InstanceState, MouseEvent)`)

  /// `worldPoint` is the mouse-down location in the same coordinate space as
  /// `state.component.bounds` (upstream's `event.getX()/getY()` before the `bds.getX()/getY()`
  /// subtraction upstream performs inline: done here instead, so the caller never has to know
  /// the component's origin).
  ///
  /// Always returns `true`, matching upstream's `init` (which upstream's poke tool interprets as
  /// "yes, start editing here"; there is no upstream path that rejects the poke).
  @discardableResult
  public func begin(at worldPoint: Location, state: any InstanceState) -> Bool {
    let bounds = state.component.bounds
    guard let data = state.data as? MemState else {
      sub = .address
      return true
    }
    let address = data.addressAt(x: worldPoint.x - bounds.x, y: worldPoint.y - bounds.y)
    if address < 0 {
      sub = .address
    } else {
      // `DataPoker`'s constructor: seat the cursor, snapshot the current value.
      data.setCursor(address)
      let value = data.contents.get(address)
      sub = .data(DataEdit(cursor: address, currentValue: value))
    }
    return true
  }

  // MARK: Key handling

  /// `keyPressed(InstanceState, KeyEvent)`, dispatched to whichever sub-poker is active. A poke
  /// that has not been started (`begin` never called) does nothing, unlike upstream, which
  /// would NPE on `sub.keyPressed`, since that upstream path is unreachable from correct tool
  /// wiring (the tool always calls `init` before delivering key events) and there is no reason
  /// to import the crash.
  public func keyPressed(_ state: any InstanceState, _ key: MemPokerNavigationKey) {
    guard let data = state.data as? MemState else { return }
    switch sub {
    case .none:
      return
    case .address:
      keyPressedAddress(data, key)
    case .data(let edit):
      keyPressedData(data, edit, key)
    }
  }

  /// `keyTyped(InstanceState, KeyEvent)`. `character` is upstream's `e.getKeyChar()`;
  /// `control` is `e.isControlDown()`.
  public func keyTyped(_ state: any InstanceState, character: Character, control: Bool) {
    guard let data = state.data as? MemState else { return }
    switch sub {
    case .none:
      return
    case .address:
      keyTypedAddress(data, character: character, control: control)
    case .data(let edit):
      keyTypedData(data, edit, state: state, character: character, control: control)
    }
  }

  /// `stopEditing(InstanceState)`. Only `DataPoker` overrides this; `AddrPoker` (and no active
  /// sub-poker) fall through to the no-op base.
  public func stopEditing(_ state: any InstanceState) {
    guard let data = state.data as? MemState, case .data = sub else { return }
    data.setCursor(-1)
  }

  // MARK: AddrPoker

  private func keyTypedAddress(_ data: MemState, character: Character, control: Bool) {
    if let digit = character.hexDigitValue {
      // `(data.getScroll() * 16 + val) & data.getLastAddress()`.
      data.setScroll((data.getScroll() &* 16 &+ Int64(digit)) & data.getLastAddress())
      return
    }
    let pageStep = (data.nrOfLines - 1) * data.nrDataSymbolsEachLine
    switch character {
    case " ":
      // Bug preserved: both the Ctrl and plain branches compute the same thing. See file header.
      data.setScroll(data.getScroll() + Int64(pageStep))
    case "\n", "\r":
      data.setScroll(
        data.getScroll() + (control ? -Int64(data.nrDataSymbolsEachLine) : Int64(data.nrDataSymbolsEachLine)))
    case "\u{08}":  // Backspace
      data.setScroll(data.getScroll() - Int64(pageStep))
    case "\u{7F}":  // Delete
      if control { data.setScroll(data.getScroll() - Int64(pageStep)) }
    case "R", "r":
      data.contents.clear()
    default:
      break
    }
  }

  private func keyPressedAddress(_ data: MemState, _ key: MemPokerNavigationKey) {
    let lineStep = Int64(data.nrDataSymbolsEachLine)
    let pageStep = Int64((data.nrOfLines - 1) * data.nrDataSymbolsEachLine)
    switch key {
    case .up, .left:
      data.setScroll(data.getScroll() - lineStep)
    case .down, .right:
      // Bug preserved: left/right move by a whole line, the same as up/down. See file header.
      data.setScroll(data.getScroll() + lineStep)
    case .pageUp:
      data.setScroll(data.getScroll() - pageStep)
    case .pageDown:
      data.setScroll(data.getScroll() + pageStep)
    }
  }

  // MARK: DataPoker

  private func moveTo(_ data: MemState, address: Int64) {
    guard data.isValidAddr(address) else { return }
    data.setCursor(address)
    data.scrollToShow(address)
    let value = data.contents.get(address)
    if case .data = sub {
      sub = .data(DataEdit(cursor: address, currentValue: value))
    }
  }

  private func keyTypedData(
    _ data: MemState, _ edit: DataEdit, state: any InstanceState, character: Character, control: Bool
  ) {
    if let digit = character.hexDigitValue {
      let newValue = edit.currentValue &* 16 &+ Int64(digit)
      sub = .data(DataEdit(cursor: edit.cursor, currentValue: newValue))
      data.contents.set(data.getCursor(), newValue)
      state.fireInvalidated()
      return
    }
    switch character {
    case " ":
      if control {
        moveTo(data, address: edit.cursor + Int64((data.nrOfLines - 1) * data.nrDataSymbolsEachLine))
      } else {
        moveTo(data, address: edit.cursor + 1)
      }
    case "\n", "\r":
      if control {
        moveTo(data, address: edit.cursor - Int64(data.nrDataSymbolsEachLine))
      } else {
        moveTo(data, address: edit.cursor + Int64(data.nrDataSymbolsEachLine))
      }
    case "\u{08}":  // Backspace
      moveTo(data, address: edit.cursor - 1)
    case "R", "r":
      data.contents.clear()
    case "\u{7F}":  // Delete
      if control {
        moveTo(data, address: edit.cursor - Int64((data.nrOfLines - 1) * data.nrDataSymbolsEachLine))
      } else {
        data.contents.set(edit.cursor, 0)
      }
    default:
      break
    }
  }

  private func keyPressedData(_ data: MemState, _ edit: DataEdit, _ key: MemPokerNavigationKey) {
    switch key {
    case .up:
      moveTo(data, address: edit.cursor - Int64(data.nrDataSymbolsEachLine))
    case .down:
      moveTo(data, address: edit.cursor + Int64(data.nrDataSymbolsEachLine))
    case .left:
      moveTo(data, address: edit.cursor - 1)
    case .right:
      moveTo(data, address: edit.cursor + 1)
    case .pageUp:
      moveTo(data, address: edit.cursor - Int64((data.nrOfLines - 1) * data.nrDataSymbolsEachLine))
    case .pageDown:
      moveTo(data, address: edit.cursor + Int64((data.nrOfLines - 1) * data.nrDataSymbolsEachLine))
    }
  }
}
