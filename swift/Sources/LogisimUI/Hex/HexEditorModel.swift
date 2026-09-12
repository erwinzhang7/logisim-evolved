// HexEditorModel.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.hex.HexEditor and the parts of
// com.cburch.hex.Caret/Highlighter that are not pure arithmetic, plus
// com.cburch.logisim.std.memory.RomAttributes.register), https://github.com/logisim-evolution/
// logisim-evolution. Copyright by the Logisim-evolution developers. This translation is a
// derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ WHAT THIS IS ═══════════════════════════════════════════════════════════════════════════
//
// `HexEditor` is a `JComponent` that is also the editor's controller: it owns the model, the
// caret, the highlighter and the measures, paints them, and routes edits. Splitting the painting
// out (`HexGridView`) leaves this; everything a test can drive without a window.
//
// It is deliberately possible to construct one, type into it, undo, load a file and save a file
// with **no view attached at all**. That is not a testing convenience bolted on afterwards; it is
// the only way to know the editor works, because the alternative is asserting on pixels.
//
// ══ MemContents IS NOT COPIED, WRAPPED, OR MIRRORED ════════════════════════════════════════
//
// The model half was already ported in M5 and is load-bearing for simulation correctness (board
// #47: one ROM bug accounted for 13 of 16 M3 defects). This type holds the *same*
// `MemContents` object the placed component holds and writes through it. There is no shadow copy
// to fall out of sync, and `MemContents.swift` is not edited by this slice.
//
// ══ THE TWO LISTENER BUGS THIS HAS TO WORK AROUND ══════════════════════════════════════════
//
// `MemContents.removeHexModelListener` is a **preserved upstream bug**: its body calls `add`, not
// `remove` (see that file's doc comment). "Unregistering" therefore registers a second time, and
// every later change fires twice. So this type never calls it. Detachment is instead by
// deallocation: `MemContents` holds listeners weakly, and `fireBytesChanged` skips the ones that
// have gone. Keeping the two listener objects as strong stored properties here, and nowhere else,
// makes the editor's lifetime the registration's lifetime.
//
// `MemContents.fill(start:length:value:)` carries a second preserved upstream bug that traps
// (Java NPEs) when a nonzero fill crosses into a not-yet-allocated page. `deleteSelection` below
// is the only caller and always passes `0`, which takes the safe arm, but that is a fact about
// this file, so anything added here that fills with a nonzero value must not use `fill`.

import Foundation
import LogisimStd

/// `com.cburch.hex.HexEditor`, minus the painting.
@MainActor
@Observable
public final class HexEditorModel {

  /// The live contents of the placed RAM/ROM. Not a copy, see the file header.
  @ObservationIgnored public let contents: MemContents

  /// `Caret`'s two fields.
  public private(set) var caret = HexCaret()

  /// The grid geometry, recomputed whenever the view reports a new width or font.
  public private(set) var measures: HexMeasures

  /// Bumped on every change to the words on screen, so a SwiftUI view has one thing to observe.
  ///
  /// `MemContents` is a plain kernel class with no `@Observable` conformance and must not gain
  /// one (D9 keeps it platform-free, and it is written from the propagation thread). A counter
  /// is the whole adaptation.
  public private(set) var revision = 0

  /// The rows the view can show at once, which is the only thing `movecursor`'s two paging
  /// branches need from the scroll view: `hex.getVisibleRect().height / measures.getCellHeight()`.
  public var visibleRows = 16

  /// `RomAttributes.register(MemContents, Project)`'s `proj`: the undo log to record into.
  ///
  /// `nil` for a ROM opened without a project and for **every RAM**: upstream registers a
  /// `RomContentsListener` from `RomAttributes` only, so RAM edits made in the hex editor are not
  /// undoable in 4.1.0 either. That asymmetry is upstream's, not this port's, and is preserved.
  @ObservationIgnored public private(set) weak var project: Project?

  /// `RomAttributes.listenerRegistry`'s value for these contents. Strong here, weak in
  /// `MemContents`, see the file header.
  @ObservationIgnored private var undoListener: RomContentsListener?

  /// The redraw listener. Also strong here and weak there.
  @ObservationIgnored private let redrawListener: HexRedrawListener

  /// Changes accumulated by `undoListener` during one edit. See `recordingUndo`.
  @ObservationIgnored private let pending = PendingHexChanges()

  /// The address range the caret may occupy, `[getFirstOffset(), getLastOffset()]`.
  public var addressBounds: ClosedRange<Int64> { contents.firstOffset...contents.lastOffset }

  public init(
    contents: MemContents,
    project: Project? = nil,
    metrics: HexFontMetrics = .guessedDefault,
    viewWidth: Int = 0
  ) {
    self.contents = contents
    self.project = project
    self.measures = HexMeasures(
      firstOffset: contents.firstOffset,
      lastOffset: contents.lastOffset,
      valueWidth: contents.valueWidth,
      metrics: metrics,
      viewWidth: viewWidth)

    let redraw = HexRedrawListener()
    self.redrawListener = redraw
    contents.addHexModelListener(redraw)

    // `RomAttributes.register`: `if (proj == null … ) return;`
    if project != nil {
      let listener = RomContentsListener()
      let pending = self.pending
      listener.onChange = { change in pending.append(change) }
      self.undoListener = listener
      contents.addHexModelListener(listener)
    }

    redraw.onChanged = { [weak self] in
      // `MemContents` fires listeners synchronously on whatever thread wrote. A user edit is
      // already on the main queue and takes `onMainActor`'s synchronous arm; a write from the
      // propagation thread (a running RAM) takes the async hop. See D1's corollary; this is
      // `onMainActor` and never `MainActor.assumeIsolated`, for the reason spelled out at
      // `LogisimFileProjectHost.swift:1471`.
      onMainActor { self?.revision &+= 1 }
    }

    // `HexFrame`'s constructor: `editor.getCaret().setDot(0, false)`.
    caret.setDot(0, keepMark: false, in: addressBounds)
  }

  // MARK: - Geometry

  /// `Measures.recompute()` + `widthChanged()`, driven by the view's layout pass.
  public func updateLayout(viewWidth: Int, metrics: HexFontMetrics) {
    let next = HexMeasures(
      firstOffset: contents.firstOffset,
      lastOffset: contents.lastOffset,
      valueWidth: contents.valueWidth,
      metrics: metrics,
      viewWidth: viewWidth)
    guard next != measures else { return }
    measures = next
  }

  /// The number of grid rows.
  public var rowCount: Int { measures.rowCount }

  /// `HexEditor.toHex(long, int)`: zero-padded lowercase hex, truncated to the low `chars`
  /// digits when the value needs more.
  public static func hex(_ value: Int64, chars: Int) -> String {
    let ret = String(format: "%0\(chars)x", value)
    return ret.count > chars ? String(ret.suffix(chars)) : ret
  }

  /// The address label for a row, as `paintComponent` draws it.
  public func rowLabel(_ row: Int) -> String {
    Self.hex(measures.baseAddress + Int64(row) * Int64(measures.columnCount), chars: measures.labelChars)
  }

  /// The first address of a row.
  public func address(row: Int, column: Int) -> Int64 {
    measures.baseAddress + Int64(row) * Int64(measures.columnCount) + Int64(column)
  }

  /// One cell's text, or `nil` where `paintComponent`'s `b >= addr0 && b <= addr1` guard skips
  /// the cell: the ragged tail of the last row.
  public func cellText(at address: Int64) -> String? {
    guard address >= contents.firstOffset, address <= contents.lastOffset else { return nil }
    return Self.hex(contents.get(address), chars: measures.cellChars)
  }

  // MARK: - Caret

  /// `Caret.setDot(long, boolean)`.
  public func setDot(_ value: Int64, keepMark: Bool = false) {
    if caret.setDot(value, keepMark: keepMark, in: addressBounds) {
      revision &+= 1
    }
  }

  /// `Caret.Listener.movecursor(int, boolean)`.
  public func move(_ motion: HexCaretMotion, extendingSelection: Bool = false) {
    let geometry = HexCaretGeometry(
      columns: measures.columnCount,
      firstOffset: contents.firstOffset,
      lastOffset: contents.lastOffset,
      visibleRows: visibleRows)
    guard let destination = geometry.destination(from: caret.dot, motion: motion) else { return }
    setDot(destination, keepMark: extendingSelection)
  }

  /// `Measures.toAddress(int, int)` followed by `Caret.setDot`: `Caret.Listener.mousePressed`
  /// and `mouseDragged` in one.
  public func selectCell(atX x: Int, y: Int, extendingSelection: Bool) {
    setDot(measures.address(atX: x, y: y), keepMark: extendingSelection)
  }

  /// `HexEditor.selectAll()`. Two `setDot` calls, in that order; the second keeps the mark the
  /// first planted at the last address, so the selection runs backwards from the end.
  public func selectAll() {
    setDot(contents.lastOffset, keepMark: false)
    setDot(0, keepMark: true)
  }

  /// `HexEditor.selectionExists()`.
  public var selectionExists: Bool { caret.selectionExists }

  // MARK: - Editing

  /// `Caret.Listener.keyTyped`'s `default` arm: a hex digit shifts the cell's current value left
  /// and ORs the digit in.
  ///
  /// Returns `false` when the character is not a hex digit (`Character.digit(c, 16) < 0`) or the
  /// caret is off the grid, which is exactly when upstream does nothing.
  ///
  /// Note there is no "start a fresh value" state: typing four digits into an 8-bit cell leaves
  /// the *last two*, because `MemContents.set` masks. That is upstream's behaviour and it is what
  /// makes typing over a cell work at all.
  @discardableResult
  public func type(_ character: Character) throws -> Bool {
    guard let digit = character.hexDigitValue else { return false }
    let cursor = caret.dot
    guard cursor >= contents.firstOffset, cursor <= contents.lastOffset else { return false }
    let current = contents.get(cursor)
    try recordingUndo {
      contents.set(cursor, 16 &* current &+ Int64(digit))
    }
    return true
  }

  /// `HexEditor.delete()`, zero the selection.
  public func deleteSelection() throws {
    guard let selection = caret.selection else { return }
    try recordingUndo {
      // `model.fill(p0, p1 - p0 + 1, 0)`. Value 0 only; see the file header on `fill`'s
      // preserved trap.
      contents.fill(
        start: selection.lowerBound,
        length: selection.upperBound - selection.lowerBound + 1,
        value: 0)
    }
  }

  // MARK: - Memory images

  /// `HexFile.open(MemContents, File)`: replace a prefix of the contents from a file.
  @discardableResult
  public func loadImage(from url: URL) throws -> Int {
    try recordingUndo {
      try HexImageFile.load(from: url, into: contents)
    }
  }

  /// `HexFile.save(File, MemContents, "v2.0 raw")`.
  public func saveImage(to url: URL) throws {
    try HexImageFile.save(contents, to: url)
  }

  /// The exact bytes `saveImage` would write. Exposed so a test can compare them to the `.circ`
  /// encoder without touching the filesystem.
  public var imageText: String { HexImageFile.encode(contents) }

  // MARK: - Undo plumbing

  /// Runs `body`, then turns whatever `MemContents` reported during it into undo-log entries.
  ///
  /// Upstream calls `proj.doAction` from inside `bytesChanged`, i.e. part-way through
  /// `MemContents.set`. Buffering and flushing after `body` returns is the one structural
  /// difference, and it is deliberate: the callback arrives on whichever thread wrote, so calling
  /// a `@MainActor` `Project` from it would have to hop, and a hop would make the undo entry
  /// arrive in a later turn of the run loop: non-deterministic, and untestable without a
  /// polling wait. The buffer keeps everything on the calling thread and preserves the order and
  /// the number of the changes, which is all `Project.doAction`'s coalescing depends on.
  ///
  /// The buffer is cleared *before* `body` runs, so a write that some other agent (a running
  /// simulation writing to a RAM) made between edits is dropped rather than attributed to the
  /// user's next keystroke. Upstream has no equivalent guard; it also never registers this
  /// listener on a RAM, so it never meets the case.
  @discardableResult
  private func recordingUndo<T>(_ body: () throws -> T) throws -> T {
    pending.reset()
    let result = try body()
    revision &+= 1
    guard let project, let listener = undoListener else {
      pending.reset()
      return result
    }
    for change in pending.take() {
      try project.doAction(
        HexEditAction(listener: listener, contents: contents, change: change))
    }
    return result
  }
}

// MARK: - Listeners

/// A `HexModelListener` whose only job is to say "something changed, redraw".
///
/// Not `@MainActor`: `HexModelListener` is declared in `LogisimStd`, which is Swift 5 language
/// mode per D1, and `MemContents` fires it from whatever thread performed the write. The hop to
/// the main actor is the closure's job, not this class's.
final class HexRedrawListener: HexModelListener, @unchecked Sendable {

  /// Set once, immediately after construction, and never again. `@unchecked Sendable` covers the
  /// stored closure: the only writer is the owning `HexEditorModel`'s `init`, before the listener
  /// can have been fired.
  var onChanged: (@Sendable () -> Void)?

  func bytesChanged(source: any HexModel, start: Int64, numBytes: Int64, oldValues: [Int64]?) {
    onChanged?()
  }

  func metainfoChanged(source: any HexModel) {
    // `HexEditor.Listener.metainfoChanged` recomputes the measures and repaints. The recompute
    // happens in the view's next layout pass, which the redraw triggers.
    onChanged?()
  }
}

/// The buffer `recordingUndo` drains. See its doc comment for why it exists.
final class PendingHexChanges: @unchecked Sendable {
  private let lock = NSLock()
  private var changes: [RomContentsChange] = []

  func append(_ change: RomContentsChange) {
    lock.lock()
    defer { lock.unlock() }
    changes.append(change)
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    changes.removeAll()
  }

  func take() -> [RomContentsChange] {
    lock.lock()
    defer { lock.unlock() }
    let result = changes
    changes.removeAll()
    return result
  }
}
