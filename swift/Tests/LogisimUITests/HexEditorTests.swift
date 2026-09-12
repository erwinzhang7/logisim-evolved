// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// CAN A USER SEE AND CHANGE WHAT IS IN A MEMORY?
//
// Before this slice, `grep -rl MemContents swift/Sources/LogisimUI/` returned nothing: a student
// could place a ROM and had no way to look inside it, which for a port whose reason to exist is
// a computer-organisation course is most of the point of the ROM.
//
// So the question this suite asks is not "does the type compile". It is:
//
//   • does typing a hex digit change the **same** `MemContents` the placed component holds
//     (not a copy, not a mirror), and does the grid then report the new value;
//   • is that edit on the project's undo stack, does ⌘Z put the old word back, and do a run of
//     adjacent edits coalesce into ONE entry rather than one per keystroke;
//   • does a memory image written here contain exactly the bytes the `.circ` encoder would
//     write: one encoder for the format, not two;
//   • does a file written here load back byte-identically, and does a format we cannot read get
//     REFUSED rather than guessed at;
//   • does the address ↔ pixel arithmetic agree with upstream's, including the three
//     `movecursor` branches that are not the obvious ones.
//
// Nothing here needs a window. That is deliberate: the alternative is asserting on pixels.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Fixtures

@MainActor
private func makeContents(addrBits: Int = 8, width: Int = 8, pattern: Bool = true) throws
  -> MemContents
{
  let contents = try MemContents.create(addrBits: addrBits, width: width, randomize: false)
  if pattern {
    for address in 0..<Int64(1) << Int64(addrBits) {
      contents.set(address, (address &* 7 &+ 3) & 0xff)
    }
  }
  return contents
}

@MainActor
private func makeProject() throws -> Project {
  Project(file: try LogisimFile.createNew(loader: Loader()))
}

// MARK: - Geometry

@Suite("Hex editor — the address ↔ pixel map (com.cburch.hex.Measures)")
struct HexMeasuresTests {

  /// Fixed, non-guessed metrics so the numbers below are arithmetic and not font-dependent.
  private static let metrics = HexFontMetrics(
    charWidth: 8, spaceWidth: 6, lineHeight: 16, guessed: false)

  @Test("label and cell widths come from the address range and the word width")
  func characterCounts() {
    // 256 words → lastOffset 255. `while (addrEnd > (1L << logSize)) logSize++` gives logSize 8,
    // so (8 + 3) / 4 = 2 label digits. An 8-bit word is (8 + 3) / 4 = 2 cell digits.
    let m = HexMeasures(
      firstOffset: 0, lastOffset: 255, valueWidth: 8, metrics: Self.metrics, viewWidth: 800)
    #expect(m.labelChars == 2)
    #expect(m.cellChars == 2)

    // A 10-bit word needs 3 digits; a 4096-word memory needs 3 label digits.
    let wide = HexMeasures(
      firstOffset: 0, lastOffset: 4095, valueWidth: 10, metrics: Self.metrics, viewWidth: 800)
    #expect(wide.labelChars == 3)
    #expect(wide.cellChars == 3)
  }

  @Test("the column count is upstream's 16/8/4 ladder, not a continuous fit")
  func columnLadder() {
    // `ret = (width - headerWidth) / (cellWidth + (spacerWidth + 3) / 4)`, then 16 / 8 / 4.
    // headerWidth = 2*8 + 6 = 22; cellWidth = 2*8 + 6 = 22; divisor = 22 + (6+3)/4 = 22 + 2 = 24.
    func columns(_ width: Int) -> Int {
      HexMeasures(
        firstOffset: 0, lastOffset: 255, valueWidth: 8, metrics: Self.metrics, viewWidth: width
      ).columnCount
    }
    #expect(columns(22 + 16 * 24) == 16)
    #expect(columns(22 + 15 * 24) == 8)
    #expect(columns(22 + 8 * 24) == 8)
    #expect(columns(22 + 7 * 24) == 4)
    #expect(columns(0) == 4)
  }

  @Test("guessed metrics pin 16 columns regardless of the view width")
  func guessedMetricsPinSixteen() {
    // `if (guessed || cellWidth < 0) cols = 16;`; the state a `Measures` is in before the
    // component has ever been painted, which is what `HexEditorModel`'s default is.
    let m = HexMeasures(
      firstOffset: 0, lastOffset: 255, valueWidth: 8, metrics: .guessedDefault, viewWidth: 10)
    #expect(m.columnCount == 16)
  }

  @Test("clicking a cell selects that cell — every column, every row")
  func hitTestRoundTrip() {
    let m = HexMeasures(
      firstOffset: 0, lastOffset: 255, valueWidth: 8, metrics: Self.metrics, viewWidth: 800)
    #expect(m.columnCount == 16)
    for address: Int64 in 0...255 {
      // The middle of the cell, where a click actually lands. See the edge-case test below for
      // why the exact left edge is a different question.
      let x = m.x(of: address) + m.cellWidth / 2
      let y = m.y(of: address) + m.cellHeight / 2
      #expect(
        m.address(atX: x, y: y) == address,
        "click in the middle of cell \(address) landed on \(m.address(atX: x, y: y))")
    }
  }

  @Test("UPSTREAM ARTIFACT PINNED: toX and toAddress use different spacer roundings")
  func hitTestEdgeDivergence() {
    // `toX` advances by `spacerWidth` every four columns: `spacerWidth / 4` per column on
    // average. `toAddress` divides by `cellWidth + (spacerWidth + 2) / 4`, an integer
    // approximation of the same thing. They agree only when `spacerWidth / 4` and
    // `(spacerWidth + 2) / 4` round alike, which for `spacerWidth = 6` they do not (1.5 vs 2).
    // The half-pixel-per-column error accumulates, so at the far right of a 16-column row the
    // exact left edge of a cell hit-tests as the cell before it.
    //
    // This is 4.1.0's arithmetic transcribed unchanged (Measures.java:168 and :180, verified in
    // upstream-java-4.1.0, not in this repo's own src/main/java, per D16). It is invisible in
    // practice because clicks land inside cells, not on their boundaries, which the round-trip
    // test above covers. Pinned so that "fixing" one of the two constants is a deliberate act.
    let m = HexMeasures(
      firstOffset: 0, lastOffset: 255, valueWidth: 8, metrics: Self.metrics, viewWidth: 800)
    #expect(m.address(atX: m.x(of: 0), y: 0) == 0)
    #expect(m.address(atX: m.x(of: 15), y: 0) == 14)
  }

  @Test("a click past the last row clamps to the last address, not past it")
  func hitTestClamps() {
    let m = HexMeasures(
      firstOffset: 0, lastOffset: 255, valueWidth: 8, metrics: Self.metrics, viewWidth: 800)
    #expect(m.address(atX: 10_000, y: 10_000) == 255)
    #expect(m.address(atX: -10_000, y: 0) == 0)
  }

  @Test("the row count covers every address exactly once")
  func rowCountCoversEverything() {
    for addrBits in 2...14 {
      let last = (Int64(1) << Int64(addrBits)) - 1
      let m = HexMeasures(
        firstOffset: 0, lastOffset: last, valueWidth: 8, metrics: Self.metrics, viewWidth: 800)
      let covered = Int64(m.rowCount) * Int64(m.columnCount)
      #expect(covered >= last + 1)
      #expect(covered - Int64(m.columnCount) < last + 1)
    }
  }
}

// MARK: - Caret

@Suite("Hex editor — caret motion (com.cburch.hex.Caret.movecursor)")
struct HexCaretTests {

  private static let geometry = HexCaretGeometry(
    columns: 16, firstOffset: 0, lastOffset: 255, visibleRows: 8)

  @Test("the four arrow keys move by one cell or one row, and stop at the edges")
  func arrows() {
    let g = Self.geometry
    #expect(g.destination(from: 20, motion: .left) == 19)
    #expect(g.destination(from: 20, motion: .right) == 21)
    #expect(g.destination(from: 20, motion: .up) == 4)
    #expect(g.destination(from: 20, motion: .down) == 36)

    // `if (cursor >= cols)` fails on row 0; the caret does NOT clamp to 0, it stays put.
    #expect(g.destination(from: 5, motion: .up) == nil)
    #expect(g.destination(from: 0, motion: .left) == nil)
    #expect(g.destination(from: 255, motion: .right) == nil)
    #expect(g.destination(from: 250, motion: .down) == nil)
  }

  @Test("Home on a row start jumps to address 0, not to the row start again")
  func homeIsTwoStage() {
    // `if (dist == 0) setDot(0, shift)`: the surprising branch, and it is deliberate upstream.
    let g = Self.geometry
    #expect(g.destination(from: 37, motion: .home) == 32)
    #expect(g.destination(from: 32, motion: .home) == 0)
  }

  @Test("End on the last cell of a row jumps to the last address in the memory")
  func endIsTwoStage() {
    // `if (dest > end || dest == cursor) dest = end;`
    let g = Self.geometry
    #expect(g.destination(from: 32, motion: .end) == 47)
    #expect(g.destination(from: 47, motion: .end) == 255)
  }

  @Test("Page Down near the bottom walks rows instead of clamping, keeping the column")
  func pageDownTail() {
    // visibleRows 8 → rows 7 → 112 cells. From 200: 200 + 112 = 312 > 255, so the tail branch
    // runs `while (n + cols < max) n += cols` from 200: 216, 232, 248, and 248 + 16 = 264 which
    // is not < 255, so it stops at 248. Note it stops *short* of the last row.
    let g = Self.geometry
    #expect(g.destination(from: 200, motion: .pageDown) == 248)
    #expect(g.destination(from: 0, motion: .pageDown) == 112)
  }

  @Test("Page Up short of a page lands on the same column of row 0")
  func pageUpTail() {
    let g = Self.geometry
    #expect(g.destination(from: 200, motion: .pageUp) == 88)
    #expect(g.destination(from: 37, motion: .pageUp) == 5)
    #expect(g.destination(from: 5, motion: .pageUp) == nil)
  }

  @Test("setDot outside the model clears the caret rather than clamping")
  func setDotClears() {
    var caret = HexCaret()
    #expect(caret.dot == -1)
    let moved = caret.setDot(10, keepMark: false, in: 0...255)
    #expect(moved)
    #expect(caret.dot == 10)
    #expect(caret.mark == 10)
    let cleared = caret.setDot(999, keepMark: false, in: 0...255)
    #expect(cleared)
    #expect(caret.dot == -1)
    #expect(!caret.selectionExists)
  }

  @Test("keepMark leaves the mark behind, which is what makes a selection")
  func keepMarkSelects() {
    var caret = HexCaret()
    caret.setDot(4, keepMark: false, in: 0...255)
    caret.setDot(9, keepMark: true, in: 0...255)
    #expect(caret.mark == 4)
    #expect(caret.dot == 9)
    #expect(caret.selection == 4...9)

    // The range is normalised, so a backwards selection reads the same way.
    caret.setDot(1, keepMark: true, in: 0...255)
    #expect(caret.selection == 1...4)
  }
}

// MARK: - Editing the real MemContents

@Suite("Hex editor — editing the memory a component actually holds")
struct HexEditorModelTests {

  @Test("typing a hex digit changes the same MemContents object, and the grid reports it")
  @MainActor
  func typingWritesThrough() throws {
    let contents = try makeContents()
    let model = HexEditorModel(contents: contents)
    model.setDot(0x10)

    let before = contents.get(0x10)
    #expect(try model.type("a"))
    // `newValue = 16 * curValue + digit`, then `MemContents.set` masks to the word width.
    #expect(contents.get(0x10) == ((before &* 16 &+ 10) & 0xff))
    #expect(model.cellText(at: 0x10) == HexEditorModel.hex(contents.get(0x10), chars: 2))
  }

  @Test("typing two digits over an 8-bit cell leaves exactly those two digits")
  @MainActor
  func typingOverwrites() throws {
    let contents = try makeContents()
    let model = HexEditorModel(contents: contents)
    model.setDot(3)
    #expect(try model.type("c"))
    #expect(try model.type("5"))
    #expect(contents.get(3) == 0xc5)
  }

  @Test("a non-hex character does nothing at all")
  @MainActor
  func nonHexIgnored() throws {
    let contents = try makeContents()
    let model = HexEditorModel(contents: contents)
    model.setDot(3)
    let before = contents.get(3)
    #expect(try model.type("z") == false)
    #expect(try model.type("!") == false)
    #expect(contents.get(3) == before)
  }

  @Test("typing with the caret off the grid is a no-op, not a crash")
  @MainActor
  func typingWithNoCaret() throws {
    let contents = try makeContents()
    let model = HexEditorModel(contents: contents)
    model.setDot(-1)
    #expect(model.caret.dot == -1)
    #expect(try model.type("a") == false)
  }

  @Test("delete zeroes the whole selection and nothing outside it")
  @MainActor
  func deleteZeroesSelection() throws {
    let contents = try makeContents()
    let model = HexEditorModel(contents: contents)
    let outsideBefore = contents.get(9)
    model.setDot(10)
    model.setDot(20, keepMark: true)
    try model.deleteSelection()

    for address in Int64(10)...20 {
      #expect(contents.get(address) == 0, "address \(address) survived the delete")
    }
    #expect(contents.get(9) == outsideBefore)
    #expect(contents.get(21) != 0)
  }

  @Test("delete spans pages — the range the grid can select is bigger than one 4096-word page")
  @MainActor
  func deleteSpansPages() throws {
    // `MemContents.PAGE_SIZE` is 4096. A 16-bit address space is 16 pages, so this crosses
    // several: the arm of `fill` that walks whole pages.
    let contents = try MemContents.create(addrBits: 16, width: 8, randomize: false)
    for address in Int64(0)..<Int64(1 << 16) { contents.set(address, 0x5a) }
    let model = HexEditorModel(contents: contents)
    model.setDot(4000)
    model.setDot(12_500, keepMark: true)
    try model.deleteSelection()

    #expect(contents.get(3999) == 0x5a)
    #expect(contents.get(4000) == 0)
    #expect(contents.get(8192) == 0)
    #expect(contents.get(12_500) == 0)
    #expect(contents.get(12_501) == 0x5a)
  }

  @Test("select all runs from the last address back to zero, as HexEditor.selectAll does")
  @MainActor
  func selectAll() throws {
    let contents = try makeContents()
    let model = HexEditorModel(contents: contents)
    model.selectAll()
    #expect(model.caret.mark == 255)
    #expect(model.caret.dot == 0)
    #expect(model.caret.selection == 0...255)
    #expect(model.selectionExists)
  }

  @Test("the row label and cell text are what paintComponent would draw")
  @MainActor
  func renderedText() throws {
    let contents = try makeContents(addrBits: 12, width: 12)
    let model = HexEditorModel(contents: contents)
    model.updateLayout(
      viewWidth: 900, metrics: HexFontMetrics(charWidth: 8, spaceWidth: 6, lineHeight: 16))
    #expect(model.measures.columnCount == 16)
    // 4096 words → logSize 12 → 3 label digits. 12-bit words → 3 cell digits.
    #expect(model.rowLabel(0) == "000")
    #expect(model.rowLabel(1) == "010")
    #expect(model.rowLabel(16) == "100")
    contents.set(0x11, 0xabc)
    #expect(model.cellText(at: 0x11) == "abc")
  }

  @Test("the ragged tail of the last row draws nothing")
  @MainActor
  func raggedTail() throws {
    // 2^5 = 32 words over 16 columns divides evenly, so build an uneven one: clamp the last
    // offset by asking for a 6-bit space and only checking past its end.
    let contents = try makeContents(addrBits: 6, width: 8)
    let model = HexEditorModel(contents: contents)
    #expect(model.cellText(at: 63) != nil)
    #expect(model.cellText(at: 64) == nil)
    #expect(model.cellText(at: -1) == nil)
  }

  @Test("the change counter moves on every edit, so the grid redraws")
  @MainActor
  func revisionAdvances() throws {
    let contents = try makeContents()
    let model = HexEditorModel(contents: contents)
    let before = model.revision
    model.setDot(5)
    #expect(model.revision > before)
    let afterCaret = model.revision
    #expect(try model.type("7"))
    #expect(model.revision > afterCaret)
  }
}

// MARK: - Undo

@Suite("Hex editor — edits go on the project's undo stack (RomContentsListener.Change)")
struct HexEditUndoTests {

  @Test("an edit is undoable, and undo puts the original word back")
  @MainActor
  func undoRestores() throws {
    let project = try makeProject()
    let contents = try makeContents()
    let model = HexEditorModel(contents: contents, project: project)
    model.setDot(0x20)
    let original = contents.get(0x20)

    #expect(!project.canUndo)
    #expect(try model.type("f"))
    #expect(contents.get(0x20) != original)
    #expect(project.canUndo)
    #expect(project.lastAction?.name == "Edit ROM Contents")

    try project.undoAction()
    #expect(contents.get(0x20) == original)

    try project.redoAction()
    #expect(contents.get(0x20) == ((original &* 16 &+ 15) & 0xff))
  }

  @Test("undoing does not record itself — the stack does not grow on ⌘Z")
  @MainActor
  func undoIsNotRecorded() throws {
    // Upstream's guard for this is `Change.doIt`/`undo`'s `source.setEnabled(false)`. In this
    // port the guard that actually carries it is `HexEditorModel.recordingUndo`'s buffer, which
    // only drains around the model's own edit methods; a red probe showed removing `setEnabled`
    // alone leaves this test green, and it goes red only when the buffer is replaced by
    // upstream's direct dispatch as well. Both are in place; this test pins the property, not
    // either mechanism.
    let project = try makeProject()
    let contents = try makeContents()
    let model = HexEditorModel(contents: contents, project: project)
    model.setDot(4)
    #expect(try model.type("9"))
    #expect(project.undoActions.count == 1)

    try project.undoAction()
    #expect(project.undoActions.count == 0)
    #expect(project.redoActions.count == 1)
  }

  @Test("a run of keystrokes over one cell coalesces into ONE undo entry")
  @MainActor
  func adjacentEditsCoalesce() throws {
    let project = try makeProject()
    let contents = try makeContents()
    let model = HexEditorModel(contents: contents, project: project)
    model.setDot(0x30)
    let original = contents.get(0x30)

    #expect(try model.type("1"))
    #expect(try model.type("2"))
    #expect(try model.type("3"))
    #expect(contents.get(0x30) == 0x23)

    // One entry, not three. This is the thing `Action` being a reference type exists to make
    // possible (see Action.swift's header) and the reason `merged(withNewer:)` was ported in M5.
    #expect(
      project.undoActions.count == 1,
      "three keystrokes left \(project.undoActions.count) undo entries")

    try project.undoAction()
    #expect(contents.get(0x30) == original)
    #expect(!project.canUndo)
  }

  @Test("edits in different parts of the memory stay separate entries")
  @MainActor
  func distantEditsDoNotCoalesce() throws {
    let project = try makeProject()
    let contents = try makeContents()
    let model = HexEditorModel(contents: contents, project: project)
    model.setDot(0x10)
    #expect(try model.type("1"))
    model.setDot(0x90)
    #expect(try model.type("2"))
    #expect(project.undoActions.count == 2)
  }

  @Test("a memory with no project still edits — it just is not undoable, as upstream has it")
  @MainActor
  func noProjectMeansNoUndo() throws {
    // `RomAttributes.register`: `if (proj == null …) return;`. Upstream registers the undo
    // listener from `RomAttributes` ONLY, so RAM edits in 4.1.0's hex editor are not undoable
    // either. Preserved, and pinned here so a later "fix" is a deliberate choice.
    let contents = try makeContents()
    let model = HexEditorModel(contents: contents, project: nil)
    model.setDot(2)
    #expect(try model.type("e"))
    #expect(contents.get(2) == ((((2 &* 7 &+ 3) & 0xff) &* 16 &+ 14) & 0xff))
  }

  @Test("UPSTREAM QUIRK PINNED: coalescing ignores which memory was edited")
  @MainActor
  func mergingIgnoresWhichMemoryWasEdited() throws {
    // `Change.shouldAppendTo`/`append` test `other instanceof Change` and the address overlap,
    // and never compare `contents`. Two hex editors open on two different ROMs in one project
    // therefore merge, and the merged action carries the FIRST memory's `contents`, so undoing
    // the pair rewrites ROM A twice and leaves ROM B edited.
    //
    // This is 4.1.0's behaviour, reproduced deliberately. The test exists so that the day someone
    // decides to diverge, it is a decision with a red test in front of it and not an accident.
    let project = try makeProject()
    let romA = try makeContents()
    let romB = try makeContents()
    let editorA = HexEditorModel(contents: romA, project: project)
    let editorB = HexEditorModel(contents: romB, project: project)

    let originalB = romB.get(0x40)
    editorA.setDot(0x40)
    #expect(try editorA.type("1"))
    editorB.setDot(0x40)
    #expect(try editorB.type("2"))

    #expect(project.undoActions.count == 1, "the two ROMs' edits did not merge")
    try project.undoAction()
    // ROM B keeps its edit: the merged action never touches it.
    #expect(romB.get(0x40) != originalB)
  }
}

// MARK: - Memory images

@Suite("Hex editor — memory images use the .circ encoder, not a second one")
struct HexImageFileTests {

  @Test("the file body is byte-identical to what the .circ codec writes")
  @MainActor
  func fileBodyIsExactlyTheCircEncoder() throws {
    // The gate this whole file exists for: two encoders for one format is a divergence waiting
    // to happen, and the existing one already round-trips ROM contents byte-exactly over 539
    // canonical corpus files. `HexImageFile` may add a header line and nothing else.
    let contents = try makeContents(addrBits: 10, width: 16)
    contents.set(start: 100, values: [0xdead, 0xdead, 0xdead, 0xdead, 0xbeef])

    let body = MemContents.saveRawToString(contents)
    #expect(HexImageFile.encode(contents) == "v2.0 raw\n" + body)

    // And the same body is what `Rom.contentsAttr` puts in a `.circ`, after its own header.
    let circ = Rom.contentsAttr.toStandardString(contents)
    #expect(circ == "addr/data: 10 16\n" + body)
  }

  @Test("the run-length encoding survives a file round trip, byte for byte")
  @MainActor
  func fileRoundTrip() throws {
    let contents = try makeContents(addrBits: 12, width: 16)
    // A long run, so the encoder emits an RLE token and the reader has to expand it.
    contents.fill(start: 0, length: 3000, value: 0x1234)
    contents.set(start: 3000, values: [1, 2, 3, 4, 5, 6, 7, 8, 9])

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("hex-round-trip-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try HexImageFile.save(contents, to: url)

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.hasPrefix("v2.0 raw\n"))
    #expect(text.contains("*"), "a 3000-word run did not produce an RLE token")

    let reloaded = try MemContents.create(addrBits: 12, width: 16, randomize: false)
    try HexImageFile.load(from: url, into: reloaded)

    for address in Int64(0)...contents.lastOffset {
      #expect(
        reloaded.get(address) == contents.get(address),
        "word \(address) differs after the round trip")
    }
    #expect(MemContents.saveRawToString(reloaded) == MemContents.saveRawToString(contents))
  }

  @Test("a file written here is what 4.1.0 would write for the same memory")
  @MainActor
  func matchesUpstreamsOwnOutput() throws {
    // `headerForFormat("v2.0 raw")` returns exactly `"v2.0 raw\n"` and `HexWriter.saveRaw`
    // writes 8 tokens per line. Both are asserted directly rather than inferred from a round
    // trip, which would pass for any self-consistent format.
    let contents = try MemContents.create(addrBits: 4, width: 8, randomize: false)
    contents.set(start: 0, values: [1, 2, 3, 4, 5, 6, 7, 8, 9, 0xa, 0xb, 0xc, 0, 0, 0, 0])
    #expect(HexImageFile.encode(contents) == "v2.0 raw\n1 2 3 4 5 6 7 8\n9 a b c\n")
  }

  @Test("an empty memory writes a header and nothing else")
  @MainActor
  func emptyMemory() throws {
    let contents = try MemContents.create(addrBits: 8, width: 8, randomize: false)
    #expect(HexImageFile.encode(contents) == "v2.0 raw\n0\n")
  }

  @Test("a short file overwrites a prefix and leaves the rest, as HexFile.open does")
  @MainActor
  func shortFileOverwritesPrefixOnly() throws {
    let destination = try MemContents.create(addrBits: 8, width: 8, randomize: false)
    for address in Int64(0)...255 { destination.set(address, 0x77) }
    try HexImageFile.load(text: "v2.0 raw\n1 2 3\n", into: destination)
    #expect(destination.get(0) == 1)
    #expect(destination.get(1) == 2)
    #expect(destination.get(2) == 3)
    // `dst.copyFrom(0, loaded, 0, loaded.getLastOffset() + 1)` copies the loaded model's whole
    // address space, and the loaded model is sized from the destination, so the tail is zeroed,
    // not left alone. Pinned because the opposite is the intuitive guess.
    #expect(destination.get(3) == 0)
    #expect(destination.get(255) == 0)
  }

  @Test("comments and blank lines before the header are skipped")
  @MainActor
  func commentsBeforeHeader() throws {
    let destination = try MemContents.create(addrBits: 8, width: 8, randomize: false)
    try HexImageFile.load(text: "# a note\n\n  v2.0 raw\n7 7 7\n", into: destination)
    #expect(destination.get(0) == 7)
  }

  @Test("a format we cannot read is REFUSED, not guessed at")
  @MainActor
  func unsupportedFormatRefused() throws {
    // Silently misreading a v3.0 byte-stream file as raw words would fill a ROM with plausible
    // garbage, which is strictly worse than refusing it.
    let destination = try MemContents.create(addrBits: 8, width: 8, randomize: false)
    #expect(throws: HexImageFileError.unsupportedFormat("v3.0 hex words plain")) {
      try HexImageFile.load(text: "v3.0 hex words plain\n01 02\n", into: destination)
    }
    #expect(throws: HexImageFileError.missingHeader) {
      try HexImageFile.load(text: "# only comments\n\n", into: destination)
    }
    #expect(throws: HexImageFileError.unsupportedFormat("01 02 03")) {
      try HexImageFile.load(text: "01 02 03\n", into: destination)
    }
    // Nothing was written by any of the three.
    #expect(destination.isClear)
  }

  @Test("loading a file replaces the contents — and is NOT undoable, exactly as 4.1.0 is not")
  @MainActor
  func loadReplacesContentsAndIsNotUndoable() throws {
    // `HexFile.open` writes through `MemContents.copyFrom`, whose closing event is
    // `fireBytesChanged(0, 1 << addrBits, /* oldValues */ null)`, and
    // `RomContentsListener.bytesChanged` returns early when `oldValues == null`. So loading a
    // memory image over a ROM cannot be undone in upstream either: ⌘Z after Open does nothing.
    //
    // Reported as an upstream defect rather than repaired here. Making it undoable means
    // snapshotting the whole memory before the copy and pushing a `HexEditAction` for it, which
    // is a real behaviour change to the undo stack and belongs in a decision, not in a UI slice.
    let project = try makeProject()
    let contents = try makeContents(addrBits: 8, width: 8)
    let model = HexEditorModel(contents: contents, project: project)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("hex-load-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("v2.0 raw\n256*ff\n".utf8).write(to: url)

    try model.loadImage(from: url)
    #expect(contents.get(0) == 0xff)
    #expect(contents.get(255) == 0xff)
    #expect(!project.canUndo, "loading became undoable — that is a divergence, not a fix")
  }

  @Test("deleting a selection IS undoable, which is what makes the asymmetry visible")
  @MainActor
  func deleteIsUndoable() throws {
    // The contrast with the test above: `fill` reports its old values, `copyFrom` does not.
    let project = try makeProject()
    let contents = try makeContents(addrBits: 8, width: 8)
    let model = HexEditorModel(contents: contents, project: project)
    let originals = (Int64(10)...20).map { contents.get($0) }
    model.setDot(10)
    model.setDot(20, keepMark: true)
    try model.deleteSelection()
    #expect(contents.get(15) == 0)
    #expect(project.canUndo)

    try project.undoAction()
    for (index, address) in (Int64(10)...20).enumerated() {
      #expect(contents.get(address) == originals[index])
    }
  }
}

// MARK: - The window

@Suite("Hex editor — the window opens programmatically and keeps one editor per memory")
struct HexWindowControllerTests {

  @Test("opening the same memory twice reuses its editor; a different memory gets its own")
  @MainActor
  func registryIsKeyedOnIdentity() throws {
    // `RomAttributes.windowRegistry` is a `WeakHashMap<MemContents, HexFrame>`: identity, not
    // value. Two ROMs holding equal bytes are two ROMs.
    let controller = HexWindowController()
    let romA = try makeContents()
    let romB = try makeContents()

    let first = controller.open(contents: romA, title: "ROM A")
    let again = controller.open(contents: romA, title: "ROM A")
    #expect(first === again)
    #expect(controller.title == "Hex Editor — ROM A")

    let other = controller.open(contents: romB, title: "ROM B")
    #expect(other !== first)
    #expect(controller.current === other)
    #expect(controller.hasEditor(for: romA))
  }

  @Test("closeEditor drops one memory's editor — the closeHexFrame path")
  @MainActor
  func closeEditorDropsIt() throws {
    let controller = HexWindowController()
    let rom = try makeContents()
    let editor = controller.open(contents: rom)
    #expect(controller.current === editor)

    controller.closeEditor(for: rom)
    #expect(!controller.hasEditor(for: rom))
    #expect(controller.current == nil)

    // Re-opening builds a fresh one rather than resurrecting the old.
    #expect(controller.open(contents: rom) !== editor)
  }

  @Test("the Close button hides the window without forgetting the editor (HIDE_ON_CLOSE)")
  @MainActor
  func closeKeepsTheEditor() throws {
    let controller = HexWindowController()
    let rom = try makeContents()
    let editor = controller.open(contents: rom)
    editor.setDot(0x20)

    controller.close()
    #expect(controller.current == nil)
    #expect(controller.hasEditor(for: rom))

    // Re-opening restores the caret, which is the user-visible half of what upstream's window
    // registry buys.
    let reopened = controller.open(contents: rom)
    #expect(reopened === editor)
    #expect(reopened.caret.dot == 0x20)
  }

  @Test("an editor opened through the controller edits the component's own contents")
  @MainActor
  func editorWritesThroughToTheComponent() throws {
    // The end-to-end shape the integrator will wire: a component's MemContents in, a changed
    // word out, with nothing copied in between.
    let project = try makeProject()
    let contents = try makeContents()
    let controller = HexWindowController()
    let editor = controller.open(contents: contents, project: project, title: "ROM")
    editor.setDot(0x55)
    #expect(try editor.type("b"))
    #expect(contents.get(0x55) == ((((0x55 &* 7 &+ 3) & 0xff) &* 16 &+ 11) & 0xff))
    #expect(project.canUndo)
  }
}
