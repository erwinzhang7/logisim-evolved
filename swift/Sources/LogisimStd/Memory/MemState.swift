// MemState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.MemState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Persistent contents vs. per-simulation state (the point of this file) ──────────────────
//
// `MemContents` (the `.circ`-serialised array) and `MemState` (this file, an `InstanceData`:
// per-`CircuitState` scratch: current address, scroll position, cursor, and the hex-grid's
// cached layout geometry) are deliberately two different objects with two different lifetimes,
// exactly as upstream keeps them separate. Collapsing them would mean a running simulation's
// cursor position and a saved file's contents share one clock, which is not what Java does and
// not what this port may do either.
//
// ── Why `open`, and the access level of its stored fields ───────────────────────────────────
//
// `RamState` (upstream: `com.cburch.logisim.std.memory.RamState extends MemState`) is owned by a
// sibling slice, not this one, and is expected to subclass this file's `MemState`; D16/D3's
// "preserve inheritance chains" rule applies here as much as anywhere. Swift has no `protected`:
// a same-module subclass declared in a different file needs at least `internal` access to reach
// inherited storage, so every field a subclass plausibly touches (all of them; Java's
// `Object.clone()` bitwise-copies the lot) is left at Swift's default `internal` rather than
// `private`. This trades a little encapsulation for the only mechanism Swift actually offers.
//
// ── `Object.clone()` has no Swift equivalent (mirrors `GateAttributes`' `copyInto` note) ────
//
// Java's `MemState.clone()`/`RamState.clone()` lean on `Object.clone()` performing a bitwise
// field copy of the *actual* (possibly subclassed) object before either override customises
// anything further. `cloneBaseState(into:)` below is the explicit stand-in a subclass's own
// `cloneData()` calls first, then layers its own fields on top; see its doc comment.
//
// ── `scrollToShow`/`setScroll` are a guaranteed no-op in this port, and that is faithful ────
//
// Both check `if (recalculateParameters) return;` first. `recalculateParameters` is flipped to
// `false` by exactly one method, `calculateDisplayParameters`, which needs font metrics. That
// method is **now ported** (M6, at the bottom of this file), so `recalculateParameters` flips to
// `false` on the first paint and both methods become live. In a headless/differential-harness
// run, no paint pass, ever, it never leaves its initial `true` and both stay unconditional
// no-ops, which is exactly upstream's behaviour for a component that has never been painted.
//
// ── PAINTING (M6) ───────────────────────────────────────────────────────────────────────────
//
// `calculateDisplayParameters(Graphics, …)` and `paint(Graphics, …)` are at the bottom of the
// class. Their supporting geometry, `getAddressAt`, `getBounds`, `getDataBounds`,
// `getDataBound`, `getFirstXoffset`, `getFirstYoffset`, `getDataBlockWidth`,
// `getDataBlockHeight`, lives in `MemPoker.swift`, which needed it first for hit-testing and
// implemented it as an extension on this class; `paint` calls straight into it rather than
// growing a second, drift-prone copy. See that file's header.
import Foundation
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.memory.MemState`: a RAM/ROM's per-`CircuitState` scratch data.
open class MemState: InstanceData, HexModelListener {

  // MARK: Stored state — every field `Object.clone()` would have copied for a subclass, too.

  var contents: MemContents
  var curScroll: Int64 = 0
  var cursorLoc: Int64 = -1
  var curAddr: Int64 = -1
  var recalculateParameters = true
  var nrOfLines = 1
  var nrDataSymbolsEachLine = 1
  var addrBlockSize = 0
  var dataBlockSize = 0
  var dataSize = 0
  var spaceSize = 0
  var xOffset = 0
  var yOffset = 0
  var charHeight = 0
  var displayWindow: Bounds?

  /// `MemState(MemContents)`.
  public init(_ contents: MemContents) {
    self.contents = contents
    setBits(addrBits: contents.logLength, dataBits: contents.valueWidth)
    contents.addHexModelListener(self)
  }

  /// The clone-time constructor: bypasses `setBits` (which would reset `curScroll`/`cursorLoc`/
  /// `curAddr` to their just-created defaults) exactly as Java's `Object.clone()` bypasses the
  /// constructor entirely. `cloneBaseState(into:)` is what actually populates a fresh instance
  /// built this way. `internal`, not `private`: `RamState` (a subclass in another file of this
  /// module, per the file header) needs `super.init(contents:)` to reach this.
  init(contents: MemContents) {
    self.contents = contents
  }

  // MARK: HexModelListener

  /// `MemState.bytesChanged`; upstream's body is empty.
  public func bytesChanged(source: any HexModel, start: Int64, numBytes: Int64, oldValues: [Int64]?) {}

  /// `MemState.metainfoChanged`.
  public func metainfoChanged(source: any HexModel) {
    setBits(addrBits: contents.logLength, dataBits: contents.valueWidth)
  }

  // MARK: InstanceData

  /// `MemState.clone()`.
  ///
  /// A subclass overrides this entirely (rather than layering a `copyInto`-style hook), because
  /// the object it must build is a *different concrete type*; Swift has no covariant
  /// `Object.clone()` to fall back on. `RamState.cloneData()` (owned by a sibling slice) is
  /// expected to read as: `let copy = RamState(contents: contents.cloneContents(), parent: nil,
  /// listener: listener); cloneBaseState(into: copy); copy.clockState = clockState; copy
  /// .contents.addHexModelListener(listener); return copy`.
  open func cloneData() -> any InstanceData {
    let copy = MemState(contents: contents.cloneContents())
    cloneBaseState(into: copy)
    copy.contents.addHexModelListener(copy)
    return copy
  }

  /// The explicit field-for-field copy `Object.clone()` performs implicitly in Java. Every
  /// `MemState` field except `contents` itself (which the caller is expected to have already
  /// deep-copied, `MemContents.cloneContents()`, before calling this) is copied verbatim.
  public func cloneBaseState(into copy: MemState) {
    copy.curScroll = curScroll
    copy.cursorLoc = cursorLoc
    copy.curAddr = curAddr
    copy.recalculateParameters = recalculateParameters
    copy.nrOfLines = nrOfLines
    copy.nrDataSymbolsEachLine = nrDataSymbolsEachLine
    copy.addrBlockSize = addrBlockSize
    copy.dataBlockSize = dataBlockSize
    copy.dataSize = dataSize
    copy.spaceSize = spaceSize
    copy.xOffset = xOffset
    copy.yOffset = yOffset
    copy.charHeight = charHeight
    copy.displayWindow = displayWindow
  }

  // MARK: Address bits

  /// `MemState.getAddrBits()`.
  public var addrBits: Int { contents.logLength }

  // MARK: Contents / current address / cursor / scroll

  /// `MemState.getContents()`.
  public func getContents() -> MemContents { contents }

  /// `MemState.getCurrent()`.
  public func getCurrent() -> Int64 { curAddr }

  /// `MemState.setCurrent(long)`.
  public func setCurrent(_ value: Int64) {
    curAddr = isValidAddr(value) ? value : -1
  }

  /// `MemState.getCursor()`.
  public func getCursor() -> Int64 { cursorLoc }

  /// `MemState.setCursor(long)`.
  public func setCursor(_ value: Int64) {
    cursorLoc = isValidAddr(value) ? value : -1
  }

  /// `MemState.getDataBits()`.
  public func getDataBits() -> Int { contents.valueWidth }

  /// `MemState.getLastAddress()`.
  public func getLastAddress() -> Int64 { javaLongBit(contents.logLength) &- 1 }

  /// `MemState.getScroll()`.
  public func getScroll() -> Int64 { curScroll }

  /// `MemState.setScroll(long)`. See the file header; a no-op while `recalculateParameters`
  /// is `true`, which it always is in a build with no paint pass (M6).
  public func setScroll(_ addr: Int64) {
    guard !recalculateParameters else { return }
    let maxAddr = Int64((1 << addrBits) - (nrOfLines * nrDataSymbolsEachLine))
    var addr = addr
    if addr > maxAddr { addr = maxAddr }
    if addr < 0 { addr = 0 }
    curScroll = addr
  }

  /// `MemState.isSplitted()`; upstream always returns `false` (only `RegisterData`'s
  /// `ShiftRegister`-adjacent sibling, not present here, ever overrides it).
  public var isSplitted: Bool { false }

  /// `MemState.isValidAddr(long)`.
  public func isValidAddr(_ addr: Int64) -> Bool {
    let bits = contents.logLength
    // `addr >>> addrBits == 0`: true exactly when every set bit of `addr` is below bit
    // `addrBits`, including for `addr < 0` (upstream relies on the unsigned shift to reject a
    // negative address here, since a negative `long` has bit 63 set).
    return MemState.javaUnsignedShift(addr, bits) == 0
  }

  /// `MemState.scrollToShow(long)`. See the file header; a no-op while `recalculateParameters`
  /// is `true`.
  public func scrollToShow(_ addr: Int64) {
    guard !recalculateParameters else { return }
    let bits = contents.logLength
    guard MemState.javaUnsignedShift(addr, bits) == 0 else { return }
    if addr < curScroll {
      let linesToScroll =
        (curScroll &- addr &+ Int64(nrDataSymbolsEachLine) &- 1) / Int64(nrDataSymbolsEachLine)
      curScroll &-= linesToScroll &* Int64(nrDataSymbolsEachLine)
    } else if addr >= curScroll &+ Int64(nrOfLines &* nrDataSymbolsEachLine) {
      let curScrollEnd = curScroll &+ Int64(nrOfLines &* nrDataSymbolsEachLine) &- 1
      let linesToScroll =
        (addr &- curScrollEnd &+ Int64(nrDataSymbolsEachLine) &- 1) / Int64(nrDataSymbolsEachLine)
      curScroll &+= linesToScroll &* Int64(nrDataSymbolsEachLine)
      let totalEntries = javaLongBit(bits)
      if curScroll &+ Int64(nrOfLines &* nrDataSymbolsEachLine) > totalEntries {
        curScroll = totalEntries &- Int64(nrOfLines &* nrDataSymbolsEachLine)
      }
    }
    if curScroll < 0 { curScroll = 0 }
  }

  // MARK: Private

  /// `MemState.setBits(int, int)`.
  ///
  /// Always called with `contents`'s *own current* dimensions (from `init` and
  /// `metainfoChanged`), so `contents.setDimensions` always takes its own same-dimensions early
  /// return and never reaches the path that can throw (`MemContentsError.invalidAddressWidth`)
  /// : D13's "internal invariant, no `.circ` file can violate it" carve-out. Upstream's own
  /// `if (contents == null) contents = MemContents.create(...)` branch is dead code for the
  /// same reason Java's is: every real construction path already has a non-null `contents`
  /// by the time this runs, so it is not reproduced.
  private func setBits(addrBits: Int, dataBits: Int) {
    recalculateParameters = true
    try! contents.setDimensions(addrBits: addrBits, width: dataBits)
    cursorLoc = -1
    curAddr = -1
    curScroll = 0
  }

  /// Java `addr >>> n` on a `long`, masked to Java's shift-distance rule (`&63`).
  private static func javaUnsignedShift(_ addr: Int64, _ n: Int) -> Int64 {
    Int64(bitPattern: UInt64(bitPattern: addr) >> UInt64(n & 63))
  }

  // MARK: - Painting (M6)

  /// `MemState.getAddressAt(int, int)`, which cell of the drawn grid a click landed on, or
  /// `-1` for a click outside it.
  ///
  /// `open`, and in the class body rather than in `MemPoker.swift`'s geometry extension with its
  /// siblings, because `DualRamState` overrides it and a Swift extension method is statically
  /// dispatched; an override there would silently never run.
  open func addressAt(x: Int, y: Int) -> Int64 {
    let yStart = yOffset
    let yStop = yStart + nrOfLines * (charHeight + 2)
    let xStart = xOffset + addrBlockSize
    let xStop = xStart + dataBlockSize
    guard x >= xStart, x <= xStop, y >= yStart, y <= yStop else { return -1 }
    // `charHeight + 2` and `dataSize` are both 0 until `calculateDisplayParameters` has run;
    // guarded rather than left to trap, matching this port's policy of never importing a crash
    // upstream itself only avoids by always painting before a click is possible.
    guard dataSize > 0, charHeight + 2 > 0 else { return -1 }
    let localX = x - xStart
    let localY = y - yStart
    let line = localY / (charHeight + 2)
    let symbol = localX / dataSize
    let pointedAddr = curScroll + Int64(line * nrDataSymbolsEachLine + symbol)
    return isValidAddr(pointedAddr) ? pointedAddr : getLastAddress()
  }

  /// `MemState.windowChanged(int, int, int, int)`.
  ///
  /// `displayWindow` is `nil` until the first `calculateDisplayParameters`, where Java's is
  /// simply an unassigned field it never reads before writing; the `recalculateParameters`
  /// guard at the call site sees to that. `nil` therefore answers "yes, changed", which routes
  /// to the same recalculation.
  private func windowChanged(_ offsetX: Int, _ offsetY: Int, _ displayWidth: Int, _ displayHeight: Int)
    -> Bool
  {
    guard let w = displayWindow else { return true }
    return w.x != offsetX || w.y != offsetY || w.width != displayWidth || w.height != displayHeight
  }

  /// `MemState.calculateDisplayParameters(Graphics, int, int, int, int)`
  /// (`MemState.java:48-83`): how many hex cells fit across and down the contents window, and
  /// where the grid starts.
  ///
  /// This is the method that makes `scrollToShow`/`setScroll` live: it is the sole assignment of
  /// `recalculateParameters = false`.
  ///
  /// Every measurement goes through the scene's own text measurer (`MemPaint.stringWidth`,
  /// `SceneBuilder.fontMetrics`), never an assumed character width; the whole grid's column
  /// pitch is `stringWidth(<one hex value> + " ")`, so guessing it would put every cell in the
  /// wrong place at any font but the one guessed for.
  private func calculateDisplayParameters(
    _ g: SceneBuilder, _ offsetX: Int, _ offsetY: Int, _ displayWidth: Int, _ displayHeight: Int
  ) {
    recalculateParameters = false
    displayWindow = Bounds.create(offsetX, offsetY, displayWidth, displayHeight)
    let addressBits = addrBits
    let dataBits = contents.valueWidth
    let fm = g.fontMetrics()

    addrBlockSize =
      ((MemPaint.stringWidth(g, MemPaint.hexString(bits: addressBits, value: 0)) + 9) / 10) * 10
    dataSize = MemPaint.stringWidth(g, MemPaint.hexString(bits: dataBits, value: 0) + " ")
    spaceSize = MemPaint.stringWidth(g, " ")

    // Java divides straight through. A measurer that reports a zero advance would make that an
    // `ArithmeticException` there and a trap here; the `== 0` correction two lines down already
    // produces the right answer for that case, so the guard just gets us to it (D13, never
    // import a crash).
    nrDataSymbolsEachLine = dataSize > 0 ? (displayWidth - addrBlockSize) / dataSize : 0
    if nrDataSymbolsEachLine == 0 { nrDataSymbolsEachLine += 1 }
    if nrDataSymbolsEachLine > 3 && nrDataSymbolsEachLine % 2 != 0 { nrDataSymbolsEachLine -= 1 }
    nrOfLines = displayHeight / (fm.height + 2)
    if nrOfLines == 0 { nrOfLines = 1 }
    var totalShowableEntries = nrDataSymbolsEachLine * nrOfLines
    let totalNrOfEntries = 1 << addressBits
    while totalShowableEntries > (totalNrOfEntries + nrDataSymbolsEachLine - 1) {
      nrOfLines -= 1
      totalShowableEntries -= nrDataSymbolsEachLine
    }
    if nrOfLines == 0 {
      nrOfLines = 1
      nrDataSymbolsEachLine = totalNrOfEntries
    }

    dataBlockSize = nrDataSymbolsEachLine * dataSize
    let totalWidth = addrBlockSize + dataBlockSize
    xOffset = offsetX + (displayWidth / 2) - (totalWidth / 2)
    charHeight = fm.height
    yOffset = offsetY
  }

  /// `MemState.paint(Graphics, int, int, int, int, int, int, int)` (`MemState.java:185-262`):
  /// the window onto the contents: a light-gray panel, the address column, and one hex value per
  /// cell, with the cells at the current address inverted.
  ///
  /// `nrItemsToHighlight` is `RamAppearance.getNrToHighlight(attrs)`, 1, or the line size for a
  /// line-enabled RAM.
  public func paint(
    _ g: SceneBuilder, leftX: Int, topY: Int, offsetX: Int, offsetY: Int,
    displayWidth: Int, displayHeight: Int, nrItemsToHighlight: Int
  ) {
    if recalculateParameters || windowChanged(offsetX, offsetY, displayWidth, displayHeight) {
      calculateDisplayParameters(g, offsetX, offsetY, displayWidth, displayHeight)
    }
    let blockHeight = nrOfLines * (charHeight + 2)
    let totalNrOfEntries = 1 << addrBits
    g.color = MemPaint.lightGray
    g.fillRect(leftX + xOffset, topY + yOffset, dataBlockSize + addrBlockSize, blockHeight)
    g.color = MemPaint.darkGray
    g.drawRect(leftX + xOffset + addrBlockSize, topY + yOffset, dataBlockSize, blockHeight)
    g.color = MemPaint.black

    // `int addr = (int) curScroll;`; the narrowing is upstream's and is reproduced, though
    // `Mem.ADDR_ATTR` caps the address width at 24 so it can never actually truncate.
    var addr = Int(Int32(truncatingIfNeeded: curScroll))
    if addr + (nrOfLines * nrDataSymbolsEachLine) > totalNrOfEntries {
      addr = totalNrOfEntries - (nrOfLines * nrDataSymbolsEachLine)
      if addr < 0 { addr = 0 }
      curScroll = Int64(addr)
    }

    let firstY = topY + firstYOffset
    let yInc = dataBlockHeight
    let firstX = leftX + firstXOffset
    for i in 0..<nrOfLines {
      g.drawText(
        MemPaint.hexString(bits: addrBits, value: Int64(addr)),
        x: leftX + xOffset + (addrBlockSize / 2),
        y: firstY + i * yInc,
        halign: .center, valign: .center)

      for j in 0..<nrDataSymbolsEachLine {
        let cell = Int64(addr + j)
        let value = contents.get(cell)
        guard isValidAddr(cell) else { continue }
        if highlight(cell, nrItemsToHighlight) {
          let dataBounds = dataBound(leftX, topY, row: i, column: j)
          g.color = MemPaint.darkGray
          g.fillRect(dataBounds.x, dataBounds.y, dataBounds.width, dataBounds.height)
          g.color = MemPaint.white
          g.drawText(
            MemPaint.hexString(bits: contents.valueWidth, value: value),
            x: firstX + j * dataSize, y: firstY + i * yInc,
            halign: .center, valign: .center)
          g.color = MemPaint.black
        } else {
          g.drawText(
            MemPaint.hexString(bits: contents.valueWidth, value: value),
            x: firstX + j * dataSize, y: firstY + i * yInc,
            halign: .center, valign: .center)
        }
      }
      addr += nrDataSymbolsEachLine
    }
  }

  /// `MemState.highLight(int, int)`.
  private func highlight(_ addr: Int64, _ nrItemsToHighlight: Int) -> Bool {
    addr >= curAddr && addr < curAddr &+ Int64(nrItemsToHighlight)
  }
}

// M6 landed. `calculateDisplayParameters` and `paint` are above; `getAddressAt`, `getBounds`,
// `getDataBounds`, `getDataBound`, `getFirstXoffset`, `getFirstYoffset`, `getDataBlockWidth` and
// `getDataBlockHeight` are in `MemPoker.swift` (see its header; it needed them first for
// hit-testing, and `paint` reuses them rather than declaring a second copy). See
// `MemState.java:48-321`. None of it is reachable from `propagate`.
