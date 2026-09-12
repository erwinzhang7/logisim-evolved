// MemContents.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.MemContents), plus the
// `com.cburch.hex.HexModel`/`HexModelListener` interfaces it implements and the "v2.0 raw"
// slice of `com.cburch.logisim.gui.hex.HexFile` that `Rom.ContentsAttribute` uses to serialise
// this class to `.circ`. https://github.com/logisim-evolution/logisim-evolution. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why `HexModel`/`HexModelListener` live here ─────────────────────────────────────────────
//
// Upstream declares them in `com.cburch.hex`, a two-file package outside `std.memory` this
// slice does not own. `MemContents` is their only implementor anywhere this port has ported so
// far, so the minimal two-method/eight-method interfaces are declared here rather than inventing
// a `HexModel.swift` this task's file list does not include. If a later slice ports the
// interactive hex editor (`com.cburch.hex.*`, all UI/M6), these declarations are the ones to
// promote to their own file; the shape will not need to change, only the location.
//
// ── The byte-exact contract ─────────────────────────────────────────────────────────────────
//
// `Rom.ContentsAttribute.toStandardString`/`.parse` (in `Rom.swift`) round-trip a RAM/ROM's
// contents through exactly one wire format: upstream's "v2.0 raw": a run-length-encoded hex
// word list, 8 tokens per line, prefixed by an `"addr/data: <addrBits> <dataWidth>\n"` header
// that lives in `Rom.swift`, not here. `saveRawToString`/`parseRaw` below are a character-for-
// character port of `HexFile.HexWriter.saveRaw()` and `HexFile.HexReader.decodeRaw()` (plus the
// `rleNextVals()` token parser they depend on): not the general HexFile format zoo (hex bytes,
// binary, escaped ASCII, the interactive format-guessing dialog). Those formats are reachable
// only from the interactive hex-editor window (`HexFrame`, UI/M6) and are not ported.
//
// The `OutputStreamEscaper(out, /* preserveWhitespace */ true, /* textWidth */ 0)` wrapper
// `HexFile.saveToString` applies is a no-op for this specific output: every character `saveRaw`
// ever writes is an ASCII digit, `*`, space or `\n`, none of which the escaper (in
// preserve-whitespace, unlimited-width mode) rewrites. Confirmed by reading
// `OutputStreamEscaper.write(int)`: only bytes outside `0x20...0x7E` (and `\` itself) or, when
// whitespace is not preserved, `\n`/`\r`/`\t` get escaped. So `saveRawToString` below emits
// exactly what `HexFile.saveToString(MemContents)` would, without needing to port the escaper.
//
// ── Paging (D: keep it) ──────────────────────────────────────────────────────────────────────
//
// `MemContentsSub`'s four `Page` subclasses (byte/short/int/long, chosen by data width) are kept
// exactly as upstream splits them; a flat `[Int64]` covering a 24-bit address space would
// allocate 8 bytes/word where upstream allocates 1, changing the memory footprint upstream's
// design deliberately trades CPU for.
//
// ── Wide/malformed address widths (D13-flavoured, not a literal Java exception) ────────────
//
// `Rom.ContentsAttribute.parse`'s "addr/data: <addr> <data>" header parses `addr`/`data` with
// plain `Integer.parseInt` (see `Rom.swift`), so a hand-edited or corrupted `contents` string can
// embed an address width completely decoupled from, and much wider than, the `Mem.ADDR_ATTR`
// the file's actual RAM/ROM declares (which is bounded to 2...24 by the attribute codec, but the
// *embedded* header is not). Upstream's `new Page[pageCount]` for a resulting negative page count
// throws `NegativeArraySizeException`: an unchecked `RuntimeException`, and while
// `Rom.ContentsAttribute.parse`'s own catch clause does not name it, it is exactly the class of
// "malformed file produces a catchable exception rather than a crash" D13 exists for. `Array(
// repeating:count:)` traps on a negative or absurd count in Swift, which is not catchable, so
// `setDimensions`/`create` below throw `MemContentsError.invalidAddressWidth` instead: turning a
// potential process crash on adversarial file content into a load error, which is strictly safer
// and never observable on any address width `Ram`/`Rom`'s own UI can produce (2...24).
import Foundation
import LogisimKernel

// MARK: - HexModel / HexModelListener

/// `com.cburch.hex.HexModelListener`.
public protocol HexModelListener: AnyObject {
  func bytesChanged(source: any HexModel, start: Int64, numBytes: Int64, oldValues: [Int64]?)
  func metainfoChanged(source: any HexModel)
}

/// `com.cburch.hex.HexModel`.
public protocol HexModel: AnyObject {
  func addHexModelListener(_ listener: HexModelListener)
  func removeHexModelListener(_ listener: HexModelListener)
  func fill(start: Int64, length: Int64, value: Int64)
  func get(_ address: Int64) -> Int64
  var firstOffset: Int64 { get }
  var lastOffset: Int64 { get }
  var valueWidth: Int { get }
  func set(_ address: Int64, _ value: Int64)
  func set(start: Int64, values: [Int64])
}

// MARK: - Errors

/// See the file header's "Wide/malformed address widths" note.
public enum MemContentsError: Error, CustomStringConvertible, Sendable {
  case invalidAddressWidth(Int)
  /// The `data:` half of a `contents` header, which was accepted verbatim until 2026-09-09;
  /// a negative width reached `MemPainter.hexString` and ended the process.
  case invalidDataWidth(Int)

  public var description: String {
    switch self {
    case .invalidAddressWidth(let bits):
      return "invalid address width \(bits) for memory contents"
    case .invalidDataWidth(let bits):
      return "invalid data width \(bits) for memory contents"
    }
  }
}

/// `com.cburch.logisim.std.memory.MemContents`: the RAM/ROM data model: a `2^addrBits`-word,
/// `width`-bit array, paged for memory-footprint reasons (see `MemContentsSub`).
///
/// A `final class`: identity matters (D4-adjacent: `RomAttributes`/`Ram`'s `windowRegistry`
/// key hex-editor windows on the specific `MemContents` instance, and `Rom.CONTENTS_ATTR`'s
/// storage form boxes it by identity via `AttributeObjectBox`).
public final class MemContents: HexModel {

  private static let pageSizeBits = 12
  /// `MemContents.PAGE_SIZE`.
  private static let pageSize = 1 << pageSizeBits
  private static let pageMask = pageSize - 1

  /// Sanity ceiling on `pages.count`, purely to turn a pathological embedded address width
  /// (see the file header) into a thrown error instead of an enormous or negative array
  /// allocation. Comfortably above anything `Ram`/`Rom`'s own `Mem.addr` (max 24 bits, so at
  /// most `2^12` pages of `2^12` words) can ever produce.
  private static let maxPageCount = 1 << 20

  private final class HexListenerBox {
    weak var listener: HexModelListener?
    init(_ listener: HexModelListener) { self.listener = listener }
  }

  /// `EventSourceWeakSupport<HexModelListener> listeners`. Weak, matching upstream's own choice
  /// of a weak listener collection (and, symmetrically, sparing `MemState`/`Mem.MemListener`,
  /// both of which register themselves here, from a retain cycle back through the attribute
  /// value that owns this object).
  private var listeners: [HexListenerBox]?

  private(set) var width: Int
  private(set) var addrBits: Int
  private var mask: Int64
  private var pages: [Page?]
  private var randomize: Bool

  private init(addrBits: Int, width: Int, randomize: Bool) throws {
    self.width = 0
    self.addrBits = 0
    self.mask = 0
    self.pages = []
    self.randomize = randomize
    try setDimensions(addrBits: addrBits, width: width)
  }

  /// `MemContents.create(int, int, boolean)`.
  public static func create(addrBits: Int, width: Int, randomize: Bool) throws -> MemContents {
    try MemContents(addrBits: addrBits, width: width, randomize: randomize)
  }

  // MARK: HexModel

  public func addHexModelListener(_ listener: HexModelListener) {
    if listeners == nil { listeners = [] }
    listeners!.append(HexListenerBox(listener))
  }

  /// `MemContents.removeHexModelListener(HexModelListener)`.
  ///
  /// ── UPSTREAM BUG, PRESERVED ──────────────────────────────────────────────────────────────
  /// Java's body is `listeners.add(l); if (listeners.isEmpty()) listeners = null;`; it calls
  /// `.add`, not `.remove`. "Unregistering" a hex-model listener from `MemContents` therefore
  /// never removes anything; it re-registers the listener a second time (and the immediately
  /// following emptiness check is dead code, since a list just appended to is never empty).
  /// Reproduced exactly: the practical consequence is that a listener registered once and later
  /// "removed" keeps firing, and fires *twice* per change from then on. Nothing in this slice
  /// (`MemState`, `Mem.MemListener`) ever calls this method, so the bug is inert for the
  /// propagate/model path this port exercises, but "fixing" it here would silently change
  /// behaviour for the first caller that does.
  public func removeHexModelListener(_ listener: HexModelListener) {
    guard listeners != nil else { return }
    listeners!.append(HexListenerBox(listener))
    if listeners!.isEmpty { listeners = nil }
  }

  /// `MemContents.fill(long, long, long)`.
  ///
  /// ── UPSTREAM BUG, PRESERVED ──────────────────────────────────────────────────────────────
  /// The `endOffs >= 0` tail branch captures `page = pages[pageEnd]` **before** calling
  /// `ensurePage(pageEnd)`. If that page did not exist yet and `value != 0`, `ensurePage`
  /// allocates a fresh page and stores it into `pages[pageEnd]`, but the already-captured local
  /// `page` still holds the old `null`, so `page.matches(...)` immediately below is a
  /// `NullPointerException` in Java. Reproduced here with a force-unwrap on the same
  /// pre-`ensurePage` snapshot, which will trap under the identical condition. Not reachable
  /// from anything this slice's `propagate`/attribute-loading code calls `fill` with: the only
  /// caller in this port, `copyFrom`'s "source page is empty" branch, always passes `value: 0`,
  /// which takes the safe `value == 0 && page == nil` arm. Only the interactive hex-editor "fill
  /// selection" feature (`HexFrame`, UI/M6, not ported) can reach the nonzero case.
  public func fill(start: Int64, length: Int64, value: Int64) {
    guard length != 0 else { return }

    var pageStart = MemContents.pageIndex(of: start)
    let startOffs = MemContents.pageOffset(of: start)
    let endAddr = start &+ length &- 1
    let pageEnd = MemContents.pageIndex(of: endAddr)
    let endOffs = MemContents.pageOffset(of: endAddr)
    let value = value & mask

    if pageStart == pageEnd {
      ensurePage(pageStart)
      let vals = [Int64](repeating: value, count: Int(length))
      let page = pages[pageStart]!
      if !page.matches(vals, Int64(startOffs), mask) {
        let oldValues = page.get(Int64(startOffs), Int(length))
        page.load(start: Int64(startOffs), values: vals, mask: mask)
        if value == 0 && page.isClear { pages[pageStart] = nil }
        fireBytesChanged(start: start, numBytes: length, oldValues: oldValues)
      }
      return
    }

    if startOffs == 0 {
      pageStart -= 1
    } else if !(value == 0 && pages[pageStart] == nil) {
      ensurePage(pageStart)
      let vals = [Int64](repeating: value, count: MemContents.pageSize - startOffs)
      let page = pages[pageStart]!
      if !page.matches(vals, Int64(startOffs), mask) {
        let oldValues = page.get(Int64(startOffs), vals.count)
        page.load(start: Int64(startOffs), values: vals, mask: mask)
        if value == 0 && page.isClear { pages[pageStart] = nil }
        // JAVA QUIRK, preserved (see `set(start:values:)`'s matching note): `numBytes` here is
        // `PAGE_SIZE - pageStart`: a page index, not a byte count.
        fireBytesChanged(
          start: start, numBytes: Int64(MemContents.pageSize - pageStart), oldValues: oldValues)
      }
    }

    if value == 0 {
      for i in (pageStart + 1)..<pageEnd where pages[i] != nil {
        clearPage(i)
      }
    } else {
      let vals = [Int64](repeating: value, count: MemContents.pageSize)
      for i in (pageStart + 1)..<pageEnd {
        ensurePage(i)
        let page = pages[i]!
        if !page.matches(vals, 0, mask) {
          let oldValues = page.get(0, MemContents.pageSize)
          page.load(start: 0, values: vals, mask: mask)
          fireBytesChanged(
            start: Int64(i << MemContents.pageSizeBits), numBytes: Int64(MemContents.pageSize),
            oldValues: oldValues)
        }
      }
    }

    if endOffs >= 0 {
      let page = pages[pageEnd]
      if !(value == 0 && page == nil) {
        ensurePage(pageEnd)
        let vals = [Int64](repeating: value, count: endOffs + 1)
        // See the doc comment above: `page` is the pre-`ensurePage` snapshot, exactly as
        // upstream captures it, so this force-unwrap traps precisely when Java NPEs.
        if !page!.matches(vals, 0, mask) {
          let oldValues = page!.get(0, endOffs + 1)
          page!.load(start: 0, values: vals, mask: mask)
          if value == 0 && page!.isClear { pages[pageEnd] = nil }
          fireBytesChanged(
            start: Int64(pageEnd << MemContents.pageSizeBits), numBytes: Int64(endOffs + 1),
            oldValues: oldValues)
        }
      }
    }
  }

  public func get(_ address: Int64) -> Int64 {
    let page = MemContents.pageIndex(of: address)
    let offs = Int64(MemContents.pageOffset(of: address))
    guard page >= 0, page < pages.count, let p = pages[page] else { return 0 }
    return p.get(offs) & mask
  }

  /// `MemContents.getFirstOffset()`.
  public var firstOffset: Int64 { 0 }

  /// `MemContents.getLastOffset()`: `(1L << addrBits) - 1`, with Java's `long`-shift masking
  /// (distance `& 63`).
  public var lastOffset: Int64 { javaLongBit(addrBits) &- 1 }

  /// `MemContents.getLogLength()`.
  public var logLength: Int { addrBits }

  public var valueWidth: Int { width }

  /// `MemContents.isClear()`.
  public var isClear: Bool {
    for page in pages {
      guard let page else { continue }
      for j in stride(from: page.length - 1, through: 0, by: -1) {
        if page.get(Int64(j)) != 0 { return false }
      }
    }
    return true
  }

  public func set(_ address: Int64, _ value: Int64) {
    let page = MemContents.pageIndex(of: address)
    let offs = Int64(MemContents.pageOffset(of: address))
    guard page >= 0, page < pages.count else { return }
    let old = pages[page] == nil ? 0 : (pages[page]!.get(offs) & mask)
    let val = value & mask
    if old != val {
      if pages[page] == nil {
        // `MemContentsSub.createPage(PAGE_SIZE, width, randomize)`; Java's lazy-creation call
        // sites (`set(long,long)`, `ensurePage`, `copyFrom`'s dest-page branch) all use the
        // literal `PAGE_SIZE` constant, not the address-width-aware `pageLength` local that only
        // `setDimensions`/`condFillRandom` bother to compute. For a memory smaller than one page
        // (`addrBits < PAGE_SIZE_BITS`) this over-allocates a 4096-word page where a correctly
        // sized one would do: harmless (every reachable offset still fits), but reproduced
        // exactly rather than "fixed", per this port's preserve-quirks-not-just-bugs mandate.
        pages[page] = MemContentsSub.createPage(size: MemContents.pageSize, bits: width, randomize: randomize)
      }
      pages[page]!.set(offs, val)
      fireBytesChanged(start: address, numBytes: 1, oldValues: [old])
    }
  }

  public func set(start: Int64, values: [Int64]) {
    if values.isEmpty { return }

    let endAddr = start &+ Int64(values.count) &- 1
    var pageStart = MemContents.pageIndex(of: start)
    let startOffs = MemContents.pageOffset(of: start)
    let pageEnd = MemContents.pageIndex(of: endAddr)
    let endOffs = MemContents.pageOffset(of: endAddr)

    // Defensive bound (beyond upstream, which would let an out-of-range `start`/`values` throw
    // `ArrayIndexOutOfBoundsException` here): every call site in this port keeps `start` and
    // `values.count` within `[0, 2^addrBits)` by construction (`MemContents.parseRaw` bounds
    // every write against `lastOffset` before calling this), so this guard is never observed to
    // fire; it exists only so a future caller's mistake fails quietly rather than crashing.
    guard pageStart >= 0, pageEnd < pages.count else { return }

    if pageStart == pageEnd {
      ensurePage(pageStart)
      let page = pages[pageStart]!
      let startOffs64 = Int64(startOffs)
      if !page.matches(values, startOffs64, mask) {
        let oldValues = page.get(startOffs64, values.count)
        page.load(start: startOffs64, values: values, mask: mask)
        if page.isClear { pages[pageStart] = nil }
        fireBytesChanged(start: start, numBytes: Int64(values.count), oldValues: oldValues)
      }
      return
    }

    var nextOffs: Int
    if startOffs == 0 {
      pageStart -= 1
      nextOffs = 0
    } else {
      ensurePage(pageStart)
      let n = MemContents.pageSize - startOffs
      let vals = Array(values[0..<n])
      let page = pages[pageStart]!
      if !page.matches(vals, Int64(startOffs), mask) {
        let oldValues = page.get(Int64(startOffs), vals.count)
        page.load(start: Int64(startOffs), values: vals, mask: mask)
        if page.isClear { pages[pageStart] = nil }
        // JAVA QUIRK, preserved: upstream fires `(start, PAGE_SIZE - pageStart, oldValues)`:
        // `PAGE_SIZE - pageStart` (a *page index*, not a byte count) rather than `vals.length`.
        // The event's `numBytes` is therefore nonsensical here; nothing in this slice reads it.
        fireBytesChanged(
          start: start, numBytes: Int64(MemContents.pageSize - pageStart), oldValues: oldValues)
      }
      nextOffs = vals.count
    }

    var offs = nextOffs
    var i = pageStart + 1
    while i < pageEnd {
      var page = pages[i]
      if page == nil {
        var allZeroes = true
        for j in 0..<MemContents.pageSize {
          if (values[offs + j] & mask) != 0 {
            allZeroes = false
            break
          }
        }
        if !allZeroes {
          page = MemContentsSub.createPage(size: MemContents.pageSize, bits: width, randomize: randomize)
          pages[i] = page
        }
      }
      if let page {
        let vals = Array(values[offs..<(offs + MemContents.pageSize)])
        if !page.matches(vals, Int64(startOffs), mask) {
          let oldValues = page.get(0, MemContents.pageSize)
          page.load(start: 0, values: vals, mask: mask)
          if page.isClear { pages[i] = nil }
          fireBytesChanged(
            start: Int64(i << MemContents.pageSizeBits), numBytes: Int64(MemContents.pageSize),
            oldValues: oldValues)
        }
      }
      offs += MemContents.pageSize
      i += 1
    }

    if endOffs >= 0 {
      ensurePage(pageEnd)
      let vals = Array(values[offs...(offs + endOffs)])
      let page = pages[pageEnd]!
      if !page.matches(vals, Int64(startOffs), mask) {
        let oldValues = page.get(0, endOffs + 1)
        page.load(start: 0, values: vals, mask: mask)
        if page.isClear { pages[pageEnd] = nil }
        fireBytesChanged(
          start: Int64(pageEnd << MemContents.pageSizeBits), numBytes: Int64(endOffs + 1),
          oldValues: oldValues)
      }
    }
  }

  // MARK: Other public methods

  /// `MemContents.clear()`.
  public func clear() {
    for i in pages.indices where pages[i] != nil {
      clearPage(i)
    }
  }

  /// `MemContents.condClear()`.
  ///
  /// Upstream reads `AppPreferences.Memory_Startup_Unknown` (default `false`), a global
  /// preference D9 forbids this module from reaching into directly. `startupUnknown` is the
  /// explicit stand-in, same shape as `Value.swift`'s `DisplayCharacters` parameter, defaulting
  /// to the preference's own out-of-the-box value, so a caller that never wires up preferences
  /// observes exactly upstream's default behaviour (a plain `clear()`).
  ///
  /// ── UPSTREAM BUG, PRESERVED ──────────────────────────────────────────────────────────────
  /// The replacement page is always sized `PAGE_SIZE` (4096), **not** the `pageLength(for:)` a
  /// small (`addrBits < 12`) memory was actually allocated with: unlike `condFillRandom` just
  /// below, which gets this right. Harmless in practice (a too-large page just wastes memory;
  /// every address `get`/`set` compute still falls inside it), but reproduced exactly rather
  /// than "fixed" to match `condFillRandom`'s more careful version.
  public func condClear(startupUnknown: Bool = false) {
    if !startupUnknown {
      clear()
    } else {
      for i in pages.indices {
        let oldValues = pages[i]?.get(0, pages[i]!.length)
        pages[i] = MemContentsSub.createPage(size: MemContents.pageSize, bits: width, randomize: randomize)
        if let oldValues {
          fireBytesChanged(start: Int64(i << MemContents.pageSizeBits), numBytes: Int64(oldValues.count), oldValues: oldValues)
        } else {
          let fresh = pages[i]!.get(0, pages[i]!.length)
          fireBytesChanged(start: Int64(i << MemContents.pageSizeBits), numBytes: Int64(pages[i]!.length), oldValues: fresh)
        }
      }
    }
  }

  /// `MemContents.condFillRandom()`.
  ///
  /// See `condClear`'s note on `startupUnknown`.
  public func condFillRandom(startupUnknown: Bool = false) {
    guard startupUnknown else { return }
    for i in pages.indices where pages[i] == nil {
      pages[i] = MemContentsSub.createPage(size: pageLength(for: i), bits: width, randomize: randomize)
    }
  }

  /// `MemContents.copyFrom(long, MemContents, long, int)`.
  public func copyFrom(_ start: Int64, _ src: MemContents, _ srcOffset: Int64, _ count: Int) throws {
    // `count = (int) Math.min(count, getLastOffset() - start + 1);`: a `long` min, narrowed by
    // a truncating (not saturating) cast, exactly like every other Java `(int)` in this file.
    let longCount = min(Int64(count), lastOffset &- start &+ 1)
    var count = wrap32(Int(longCount))
    guard count > 0 else { return }
    guard src.addrBits == addrBits else {
      throw MemContentsError.invalidAddressWidth(src.addrBits)
    }
    guard srcOffset &+ Int64(count) &- 1 <= src.lastOffset else {
      throw MemContentsError.invalidAddressWidth(addrBits)
    }

    var dp = MemContents.pageIndex(of: start)
    var di = MemContents.pageOffset(of: start)
    var sp = MemContents.pageIndex(of: srcOffset)
    var si = MemContents.pageOffset(of: srcOffset)

    repeat {
      let dstPage = pages[dp]
      let srcPage = src.pages[sp]
      let n = min(count, min(MemContents.pageSize - si, MemContents.pageSize - di))
      if dstPage == nil && srcPage == nil {
        // both already all zeros
      } else if srcPage == nil {
        fill(start: Int64(dp * MemContents.pageSize + di), length: Int64(n), value: 0)
      } else {
        if pages[dp] == nil {
          // Literal `PAGE_SIZE`, matching Java's `copyFrom`; see the note on `set(_:_:)` above.
          pages[dp] = MemContentsSub.createPage(size: MemContents.pageSize, bits: width, randomize: randomize)
        }
        let vals = srcPage!.get(Int64(si), n)
        pages[dp]!.set(Int64(di), vals)
      }
      count -= n
      di += n
      si += n
      if di >= MemContents.pageSize {
        di = 0
        dp += 1
      }
      if si >= MemContents.pageSize {
        si = 0
        sp += 1
      }
    } while count > 0
    fireBytesChanged(start: 0, numBytes: javaLongBit(addrBits), oldValues: nil)
  }

  /// `MemContents.setDimensions(int, int)`.
  public func setDimensions(addrBits: Int, width: Int) throws {
    // The DATA width is validated here as well as the address width, and it was not.
    //
    // `Rom.contentsAttr`'s parse reads the `addr/data:` header with `javaParseInt32`, which
    // accepts any Int32 including a negative, and stored it verbatim: this function's own
    // comment already anticipated a negative `addrBits` "from the malformed-header path" and
    // simply did not consider the other half of the same header. A width of -8 then reaches
    // `MemPainter.hexString`, where `len = (bits + 3) / 4` is -1 and `digits.suffix(-1)` is a
    // precondition failure that ends the process.
    //
    // 4.1.0 fails on the same input too, but RECOVERABLY: `StringUtil.toHexString` builds the
    // format `"%0" + (-1) + "x"` and `java.util.Formatter` throws `IllegalFormatFlagsException`,
    // a catchable `RuntimeException`, so the component fails to paint and the app survives. So
    // this is a recoverable-to-fatal regression rather than a correct-to-wrong one: a lesser
    // class than the Divider, and still not something to ship.
    //
    // Refusing at the choke point rather than defending inside the painter is deliberate: the
    // width is stored once and read from many places (`MemState.swift:385`'s `contents.get(cell)`
    // before its `isValidAddr` guard shares this root cause), and upstream's
    // `ContentsAttribute.parse` already returns null on a malformed header, so rejecting here is
    // the documented behaviour rather than an invention.
    guard width >= 1, width <= 64 else {
      throw MemContentsError.invalidDataWidth(width)
    }
    if addrBits == self.addrBits && width == self.width { return }
    self.addrBits = addrBits
    self.width = width
    self.mask = width == 64 ? -1 : (javaLongBit(width) &- 1)

    let oldPages = pages
    let pageCount: Int
    let pageLength: Int
    if addrBits < MemContents.pageSizeBits {
      pageCount = 1
      // `1 << addrBits`: Java masks the `int` shift distance to `&31`. `addrBits` here is
      // already `< PAGE_SIZE_BITS` (12), so the mask never bites in the ordinary (non-negative)
      // case; a negative `addrBits` from the malformed-header path (file header note above) is
      // exactly what `wrap32Shift` below exists to reproduce faithfully rather than trap.
      pageLength = MemContents.wrap32Shift(addrBits)
    } else {
      pageCount = MemContents.wrap32Shift(addrBits - MemContents.pageSizeBits)
      pageLength = MemContents.pageSize
    }
    guard pageCount > 0, pageCount <= MemContents.maxPageCount, pageLength > 0 else {
      throw MemContentsError.invalidAddressWidth(addrBits)
    }

    var newPages = [Page?](repeating: nil, count: pageCount)
    // `if (pageCount == 0 && pages[0] == null)`: JAVA QUIRK, dead code. `1 << n` for a masked
    // `int` shift distance `n` in `0...31` is never literally `0`, so this branch is provably
    // unreachable and is not reproduced (see file header discussion for the reasoning this
    // mirrors: an established-dead Java branch is noted, not transcribed).
    let n = min(oldPages.count, newPages.count)
    for i in 0..<n {
      guard let old = oldPages[i] else { continue }
      let fresh = MemContentsSub.createPage(size: pageLength, bits: width, randomize: randomize)
      let m = min(old.length, pageLength)
      for j in 0..<m {
        fresh.set(Int64(j), old.get(Int64(j)))
      }
      newPages[i] = fresh
    }
    pages = newPages

    fireMetainfoChanged()
  }

  public func cloneContents() -> MemContents {
    // `MemContents.clone()`. Java's `Object.clone()` copies every field shallowly and then
    // this method deep-copies `pages`; the port does the same directly since Swift has no
    // `Object.clone()` to lean on.
    let copy = try! MemContents(addrBits: addrBits, width: width, randomize: randomize)
    copy.mask = mask
    copy.pages = pages.map { $0?.clonePage() }
    return copy
  }

  // MARK: Private helpers

  private func pageLength(for pageIndex: Int) -> Int {
    addrBits < MemContents.pageSizeBits ? MemContents.wrap32Shift(addrBits) : MemContents.pageSize
  }

  private func ensurePage(_ index: Int) {
    if pages[index] == nil {
      // Literal `PAGE_SIZE`, matching Java's `ensurePage`; see the note on `set(_:_:)` above.
      pages[index] = MemContentsSub.createPage(size: MemContents.pageSize, bits: width, randomize: randomize)
    }
  }

  private func clearPage(_ index: Int) {
    guard let page = pages[index] else { return }
    var oldValues = [Int64](repeating: 0, count: page.length)
    var changed = false
    for j in 0..<oldValues.count {
      let val = page.get(Int64(j)) & mask
      oldValues[j] = val
      if val != 0 { changed = true }
    }
    if changed {
      pages[index] = nil
      fireBytesChanged(start: Int64(index << MemContents.pageSizeBits), numBytes: Int64(oldValues.count), oldValues: oldValues)
    }
  }

  private func fireBytesChanged(start: Int64, numBytes: Int64, oldValues: [Int64]?) {
    guard let boxes = listeners else { return }
    var found = false
    for box in boxes {
      guard let listener = box.listener else { continue }
      found = true
      listener.bytesChanged(source: self, start: start, numBytes: numBytes, oldValues: oldValues)
    }
    if !found { listeners = nil }
  }

  private func fireMetainfoChanged() {
    guard let boxes = listeners else { return }
    var found = false
    for box in boxes {
      guard let listener = box.listener else { continue }
      found = true
      listener.metainfoChanged(source: self)
    }
    if !found { listeners = nil }
  }

  /// Java `(int) (addr >>> PAGE_SIZE_BITS)`: an *unsigned* `long` right shift, then narrowed
  /// to `int`. Swift's `>>` on `Int64` is arithmetic (sign-extending), which only diverges from
  /// Java's `>>>` for a negative `addr`; every real call site keeps `addr` non-negative, but the
  /// malformed-header path (file header note) can hand this a value derived from an
  /// out-of-range `Integer.parseInt`, so the unsigned shift is reproduced exactly rather than
  /// assumed away.
  fileprivate static func pageIndex(of addr: Int64) -> Int {
    let shifted = UInt64(bitPattern: addr) >> UInt64(pageSizeBits)
    return wrap32(Int(bitPattern: UInt(shifted)))
  }

  /// Java `(int) (addr & PAGE_MASK)`.
  fileprivate static func pageOffset(of addr: Int64) -> Int {
    wrap32(Int(addr & Int64(pageMask)))
  }

  /// Java `1 << n` as `int` arithmetic (shift distance masked `&31`, then widened back to
  /// `Int` for array-size use). Matches upstream's `int pageCount`/`pageLength` locals exactly,
  /// including their sign if bit 31 ends up set, which `setDimensions` then rejects via the
  /// `pageCount > 0` guard rather than letting a negative count reach `Array(repeating:count:)`.
  fileprivate static func wrap32Shift(_ n: Int) -> Int {
    Int(Int32(truncatingIfNeeded: javaIntBitWidened(n)))
  }
}

// MARK: - "v2.0 raw" hex codec (`HexFile.HexWriter.saveRaw` / `HexReader.decodeRaw`)

extension MemContents {

  /// `Long.toHexString(long)`: the value's *unsigned* 64-bit hex form, lowercase, no leading
  /// zeros (`0` prints as `"0"`, not `""`). Swift's `String(UInt64, radix: 16)` already has
  /// exactly this shape.
  fileprivate static func javaLongToHexString(_ value: Int64) -> String {
    String(UInt64(bitPattern: value), radix: 16)
  }

  /// `HexFile.saveToString(MemContents)`, restricted to "v2.0 raw" (the only format `Rom`'s
  /// `contents` attribute ever uses: see the file header). A character-for-character port of
  /// `HexWriter.saveRaw()`: run-length-encode runs of 4 or more identical words as
  /// `"<count>*<hex>"`, everything else as a bare `"<hex>"`, tokens separated by a space except
  /// every 8th, which starts a new line, with a trailing `"\n"` if anything was written at all.
  ///
  /// The `OutputStreamEscaper` wrapper `HexFile.saveToString` applies around this is a no-op for
  /// this alphabet (digits, `*`, space, `\n`), see the file header, so it is not ported.
  public static func saveRawToString(_ contents: MemContents) -> String {
    var memEnd = contents.lastOffset
    while memEnd > 0 && contents.get(memEnd) == 0 { memEnd -= 1 }

    var out = ""
    var tokens = 0
    var offs: Int64 = 0
    while offs <= memEnd {
      let val = contents.get(offs)
      let start = offs
      offs &+= 1
      while offs <= memEnd && contents.get(offs) == val { offs &+= 1 }
      var len = offs &- start
      if len < 4 {
        offs = start &+ 1
        len = 1
      }
      if tokens > 0 { out.append(tokens % 8 == 0 ? "\n" : " ") }
      if offs != start &+ 1 { out += "\(offs &- start)*" }
      out += javaLongToHexString(val)
      tokens += 1
    }
    if tokens > 0 { out.append("\n") }
    return out
  }

  /// `HexFile.parseFromCircFile(String, int, int)`, restricted to "v2.0 raw". A
  /// character-for-character port of `HexReader.decodeRaw()` plus the `rleNextVals()` token
  /// parser it depends on. The fixed 4096-word batching is observable for 9...16-bit memories:
  /// D16's `ShortPage.load` has a mid-page bulk-write quirk, so adjacent tokens must be combined
  /// into the same batch exactly as Java combines them.
  ///
  /// Malformed tokens are skipped (upstream `warn()`s and `continue`s); this port drops the
  /// warning text, nothing in the non-interactive `decode()` path upstream actually calls
  /// reads it (only the interactive format-picker dialog, `HexFormatDialog`, UI/M6, does), but
  /// preserves the *skip*, which is the only part that affects `dst`'s final contents.
  public static func parseRaw(_ text: String, addrBits: Int, width: Int) throws -> MemContents {
    let dst = try MemContents.create(addrBits: addrBits, width: width, randomize: false)
    let memEnd = dst.lastOffset

    var scanner = RawWordScanner(text)
    scanner.findNonemptyLine(skipHeader: true)

    // `rleNextVals()` batches expansion through a 4096-`long` scratch buffer, resuming a run
    // across calls. Keeping that batching is required for byte-for-byte D16 behaviour.
    var offs: Int64 = 0
    var rleCount: Int64 = 0
    var rleValue: Int64 = 0

    while rleCount > 0 || scanner.hasNextWord() {
      var values: [Int64] = []
      values.reserveCapacity(MemContents.pageSize)

      if rleCount > 0 {
        let n = min(Int64(MemContents.pageSize), rleCount)
        values.append(contentsOf: repeatElement(rleValue, count: Int(n)))
        rleCount &-= n
      }

      while values.count < MemContents.pageSize, let word = scanner.nextWord() {
        let star = word.firstIndex(of: "*")
        let hexPart: Substring
        let countPart: Substring?
        if let star {
          if star == word.startIndex {
            // "*data"; missing count. Upstream warns and skips the token entirely.
            continue
          }
          let afterStar = word.index(after: star)
          if afterStar == word.endIndex {
            // "count*"; missing hex data. Upstream warns and skips the token entirely.
            continue
          }
          hexPart = word[afterStar...]
          countPart = word[word.startIndex..<star]
        } else {
          hexPart = word[...]
          countPart = nil
        }

        guard let value = javaParseHexLong(String(hexPart)) else {
          continue  // "not valid hex data" — skip.
        }

        let count: Int64
        if let countPart {
          guard let parsedCount = javaParseUnsignedDecimalLong(String(countPart)) else {
            continue  // "not valid (base-10 decimal) count" — skip.
          }
          count = parsedCount
        } else {
          count = 1
        }

        guard count > 0 else {
          // A token can legitimately parse to a zero count (e.g. "0*ff"); upstream's loop would
          // spin writing nothing and never advance `offs`, which for `dst.set`'s purposes is
          // observationally identical to just not advancing at all.
          continue
        }

        rleValue = value
        rleCount = count
        let n = min(Int64(MemContents.pageSize - values.count), rleCount)
        values.append(contentsOf: repeatElement(rleValue, count: Int(n)))
        rleCount &-= n
      }

      if offs <= memEnd {
        let batchCount = Int64(values.count)
        let end = offs &+ batchCount &- 1
        let n = end > memEnd ? (memEnd &- offs &+ 1) : batchCount
        if n > 0 {
          dst.set(start: offs, values: Array(values.prefix(Int(n))))
        }
      }
      offs &+= Int64(values.count)
    }

    return dst
  }

  /// `Long.parseUnsignedLong(s, 16)`, falling back to `Long.parseLong(s, 16)`; the dual attempt
  /// `HexReader.rleNextVals()` makes so a token like `"-1"` (a signed literal, valid only via the
  /// second, non-unsigned parser) still resolves. Swift's `UInt64.init?(_:radix:)` already
  /// rejects a leading `-` the way `parseUnsignedLong` does, and `Int64.init?(_:radix:)` accepts
  /// one the way `parseLong` does, so the two together reproduce the fallback without needing to
  /// hand-parse the sign.
  fileprivate static func javaParseHexLong(_ s: String) -> Int64? {
    if let unsigned = UInt64(s, radix: 16) { return Int64(bitPattern: unsigned) }
    return Int64(s, radix: 16)
  }

  /// `Long.parseUnsignedLong(s)` (radix 10) for a run-length count.
  fileprivate static func javaParseUnsignedDecimalLong(_ s: String) -> Int64? {
    guard let unsigned = UInt64(s, radix: 10) else { return nil }
    return Int64(bitPattern: unsigned)
  }

  /// The line/word tokenizer behind `HexReader.findNonemptyLine`/`hasNextWord`/`nextWord`,
  /// specialised to what `decodeRaw` actually needs (no addressed-hex double-space handling,
  /// no warning text: see `parseRaw`'s doc comment).
  fileprivate struct RawWordScanner {
    private let lines: [String]
    private var lineIndex = 0
    private var words: [Substring] = []
    private var wordIndex = 0

    init(_ text: String) {
      lines = MemContents.javaReadLines(text)
    }

    /// `HexReader.findNonemptyLine(boolean)`.
    mutating func findNonemptyLine(skipHeader: Bool) {
      words = []
      wordIndex = 0
      var skip = skipHeader
      while lineIndex < lines.count {
        var line = Substring(lines[lineIndex])
        lineIndex += 1
        if let hash = line.firstIndex(of: "#") {
          line = line[line.startIndex..<hash]
        }
        if skip {
          let trimmed = javaTrim(line)
          if trimmed.isEmpty { continue }
          skip = false
          if trimmed.first == "v" { continue }
          line = Substring(trimmed)
        }
        let trimmed = javaTrim(line)
        if trimmed.isEmpty { continue }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
        if !parts.isEmpty {
          words = parts
          wordIndex = 0
          return
        }
      }
    }

    /// `HexReader.hasNextWord()`.
    mutating func hasNextWord() -> Bool {
      if wordIndex >= words.count { findNonemptyLine(skipHeader: false) }
      return wordIndex < words.count
    }

    /// `HexReader.nextWord()`.
    mutating func nextWord() -> String? {
      guard hasNextWord() else { return nil }
      defer { wordIndex += 1 }
      return String(words[wordIndex])
    }
  }

  /// `BufferedLineReader.readLine()`'s line-splitting rule: `\n`, `\r`, and `\r\n` all terminate
  /// a line; the final line is returned even without a trailing terminator; a wholly empty input
  /// yields no lines at all (not one empty line).
  fileprivate static func javaReadLines(_ text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    let chars = Array(text)
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c == "\n" {
        lines.append(current)
        current = ""
        i += 1
      } else if c == "\r" {
        lines.append(current)
        current = ""
        i += 1
        if i < chars.count && chars[i] == "\n" { i += 1 }
      } else {
        current.append(c)
        i += 1
      }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
  }
}

extension MemContents {
  /// `com.cburch.logisim.std.memory.MemContents.Page`: abstract per-page storage.
  ///
  /// Nested to match Java's `MemContents.Page` namespacing; `MemContentsSub.swift`'s four
  /// concrete pages subclass this from a different file in the same module, which Swift allows
  /// as long as the nested type is not `final` (it is `open`, matching every other abstract
  /// stub in this codebase).
  open class Page {
    public init() {}

    /// `Page.get(long)`.
    open func get(_ addr: Int64) -> Int64 {
      fatalError("Page subclasses must override get(_:)")
    }

    /// `Page.get(long, int)`.
    open func get(_ start: Int64, _ len: Int) -> [Int64] {
      var ret = [Int64](repeating: 0, count: len)
      for i in 0..<len { ret[i] = get(start &+ Int64(i)) }
      return ret
    }

    /// `Page.set(long, long)`.
    open func set(_ addr: Int64, _ value: Int64) {
      fatalError("Page subclasses must override set(_:_:)")
    }

    /// `Page.set(long, long[])`.
    open func set(_ start: Int64, _ values: [Int64]) {
      for i in 0..<values.count { set(start &+ Int64(i), values[i]) }
    }

    /// `Page.getLength()`.
    open var length: Int {
      fatalError("Page subclasses must override length")
    }

    /// `Page.isClear()`.
    open var isClear: Bool {
      for i in 0..<length where get(Int64(i)) != 0 { return false }
      return true
    }

    /// `Page.load(long, long[], long)`.
    open func load(start: Int64, values: [Int64], mask: Int64) {
      fatalError("Page subclasses must override load(start:values:mask:)")
    }

    /// `Page.matches(long[], long, long)`.
    open func matches(_ values: [Int64], _ start: Int64, _ mask: Int64) -> Bool {
      for i in 0..<values.count where get(start &+ Int64(i)) != (values[i] & mask) { return false }
      return true
    }

    /// `Page.clone()`.
    open func clonePage() -> Page {
      fatalError("Page subclasses must override clonePage()")
    }
  }
}
