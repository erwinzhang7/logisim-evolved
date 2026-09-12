// MemContentsSub.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.MemContentsSub),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why four page types ──────────────────────────────────────────────────────────────────────
//
// `MemContents.Page` is nested in `MemContents.swift`; this file supplies the four concrete
// backing stores upstream chooses between by data width, so a 4-bit-wide 16M-word ROM allocates
// one byte per word instead of eight. Keeping this split (rather than collapsing to one
// `[Int64]`-backed page, which would be the natural Swift shape) is the memory-footprint
// property the task brief calls out by name; see `MemContents.swift`'s file header.
//
// ── Randomisation ────────────────────────────────────────────────────────────────────────────
//
// Upstream reads `AppPreferences.Memory_Startup_Unknown.get()` inside each page's constructor:
// a second call site for the same preference `MemContents.condClear`/`condFillRandom` already
// front with an explicit `startupUnknown` parameter (D9; see that file's note). `createPage`
// takes the same parameter here, defaulting to the preference's own out-of-the-box value
// (`false`), so a page is randomised only when a caller explicitly asks for it: never as a side
// effect of `MemContents.create`'s own `randomize` flag alone, exactly as upstream requires both
// `Memory_Startup_Unknown` *and* the page's own `randomize` bit to be true.
//
// Upstream's `java.util.Random()` (unseeded, one instance *per page allocation*) is not
// reproduced bit-for-bit; no test in this port's differential harness depends on a specific
// startup-garbage byte sequence (RAM/ROM content is always either explicit `.circ` data or a
// deterministic zero-fill; "unknown startup content" is, definitionally, meant to be arbitrary).
// `SystemRandomNumberGenerator` stands in.
import Foundation
import LogisimKernel

enum MemContentsSub {

  /// `MemContentsSub.createPage(int, int, boolean)`.
  static func createPage(
    size: Int, bits: Int, randomize: Bool, startupUnknown: Bool = false
  ) -> MemContents.Page {
    let mask: Int64 = bits == 64 ? -1 : (javaLongBit(bits) &- 1)
    if bits <= 8 {
      return BytePage(size: size, mask: mask, randomize: randomize, startupUnknown: startupUnknown)
    } else if bits <= 16 {
      return ShortPage(size: size, mask: mask, randomize: randomize, startupUnknown: startupUnknown)
    } else if bits <= 32 {
      return IntPage(size: size, mask: mask, randomize: randomize, startupUnknown: startupUnknown)
    } else {
      return LongPage(size: size, mask: mask, randomize: randomize, startupUnknown: startupUnknown)
    }
  }

  // MARK: - BytePage

  /// `MemContentsSub.BytePage`.
  fileprivate final class BytePage: MemContents.Page {
    private var data: [Int8]

    init(size: Int, mask: Int64, randomize: Bool, startupUnknown: Bool) {
      data = [Int8](repeating: 0, count: size)
      if startupUnknown && randomize {
        for i in data.indices {
          data[i] = Int8(truncatingIfNeeded: Int64(Int.random(in: 0..<256)) & mask)
        }
      }
    }

    private init(copying data: [Int8]) { self.data = data }

    override func get(_ addr: Int64) -> Int64 {
      guard addr >= 0, addr < data.count else { return 0 }
      return Int64(data[Int(addr)])
    }

    override var length: Int { data.count }

    override func load(start: Int64, values: [Int64], mask: Int64) {
      let n = min(values.count, data.count - Int(start))
      for i in 0..<n { data[Int(start) + i] = Int8(truncatingIfNeeded: values[i] & mask) }
    }

    override func set(_ addr: Int64, _ value: Int64) {
      guard addr >= 0, addr < data.count else { return }
      let newValue = Int8(truncatingIfNeeded: value)
      if data[Int(addr)] != newValue { data[Int(addr)] = newValue }
    }

    override func clonePage() -> MemContents.Page { BytePage(copying: data) }
  }

  // MARK: - ShortPage

  /// `MemContentsSub.ShortPage`.
  fileprivate final class ShortPage: MemContents.Page {
    private var data: [Int16]

    init(size: Int, mask: Int64, randomize: Bool, startupUnknown: Bool) {
      data = [Int16](repeating: 0, count: size)
      if startupUnknown && randomize {
        for i in data.indices {
          data[i] = Int16(truncatingIfNeeded: Int64(Int.random(in: 0..<(1 << 16))) & mask)
        }
      }
    }

    private init(copying data: [Int16]) { self.data = data }

    override func get(_ addr: Int64) -> Int64 {
      guard addr >= 0, addr < data.count else { return 0 }
      return Int64(data[Int(addr)])
    }

    override var length: Int { data.count }

    /// `ShortPage.load(long, long[], long)`.
    ///
    /// ── UPSTREAM BUG, PRESERVED ──────────────────────────────────────────────────────────────
    /// Every other `Page.load` copies `values[0 ..< n]` into `data[start ..< start+n]`. This one
    /// (a "bugfix… by Roy77" per the upstream comment) instead loops `for (i = start; i < n;
    /// i++)` and writes `data[start + i]` from `values[i]`; both the loop bound *and* the
    /// destination index are off, since `i` already starts at `start`. For `start == 0` this is
    /// harmless (the loop is exactly `0..<n`, matching every other page type). For `start > 0`
    /// it reads/writes from an offset shifted by `start` a second time and iterates too few
    /// times, silently loading the wrong words at the wrong offsets for any bulk write that does
    /// not begin at the start of a page. Upstream's own comment frames this as an intentional
    /// fix, not a slip, so it is reproduced exactly rather than "corrected" back to the pattern
    /// the other three page types use; doing so would change what a wide (9–16-bit) memory's
    /// mid-page bulk load actually stores.
    override func load(start: Int64, values: [Int64], mask: Int64) {
      let n = min(values.count, data.count - Int(start))
      var i = Int(start)
      while i < n {
        let idx = Int(start) + i
        guard idx >= 0, idx < data.count, i >= 0, i < values.count else { break }
        data[idx] = Int16(truncatingIfNeeded: values[i] & mask)
        i += 1
      }
    }

    override func set(_ addr: Int64, _ value: Int64) {
      guard addr >= 0, addr < data.count else { return }
      let newValue = Int16(truncatingIfNeeded: value)
      if data[Int(addr)] != newValue { data[Int(addr)] = newValue }
    }

    override func clonePage() -> MemContents.Page { ShortPage(copying: data) }
  }

  // MARK: - IntPage

  /// `MemContentsSub.IntPage`.
  fileprivate final class IntPage: MemContents.Page {
    private var data: [Int32]

    init(size: Int, mask: Int64, randomize: Bool, startupUnknown: Bool) {
      data = [Int32](repeating: 0, count: size)
      if startupUnknown && randomize {
        for i in data.indices {
          data[i] = Int32(truncatingIfNeeded: Int64(Int32.random(in: Int32.min...Int32.max)) & mask)
        }
      }
    }

    private init(copying data: [Int32]) { self.data = data }

    override func get(_ addr: Int64) -> Int64 {
      guard addr >= 0, addr < data.count else { return 0 }
      return Int64(data[Int(addr)])
    }

    override var length: Int { data.count }

    override func load(start: Int64, values: [Int64], mask: Int64) {
      let n = min(values.count, data.count - Int(start))
      for i in 0..<n { data[Int(start) + i] = Int32(truncatingIfNeeded: values[i] & mask) }
    }

    override func set(_ addr: Int64, _ value: Int64) {
      guard addr >= 0, addr < data.count else { return }
      let newValue = Int32(truncatingIfNeeded: value)
      if data[Int(addr)] != newValue { data[Int(addr)] = newValue }
    }

    override func clonePage() -> MemContents.Page { IntPage(copying: data) }
  }

  // MARK: - LongPage

  /// `MemContentsSub.LongPage`.
  fileprivate final class LongPage: MemContents.Page {
    private var data: [Int64]

    init(size: Int, mask: Int64, randomize: Bool, startupUnknown: Bool) {
      data = [Int64](repeating: 0, count: size)
      if startupUnknown && randomize {
        // `(int) generator.nextLong() & mask`: upstream narrows to `int` *before* masking,
        // so only the low 32 bits of the random draw ever survive even for a 64-bit-wide page.
        // Reproduced: this is why upstream's own comment above `LongPage` calls it out as
        // narrower than its name suggests.
        for i in data.indices {
          let narrowed = Int32(truncatingIfNeeded: Int64.random(in: Int64.min...Int64.max))
          data[i] = Int64(narrowed) & mask
        }
      }
    }

    private init(copying data: [Int64]) { self.data = data }

    override func get(_ addr: Int64) -> Int64 {
      guard addr >= 0, addr < data.count else { return 0 }
      return data[Int(addr)]
    }

    override var length: Int { data.count }

    override func load(start: Int64, values: [Int64], mask: Int64) {
      let n = min(values.count, data.count - Int(start))
      for i in 0..<n { data[Int(start) + i] = values[i] & mask }
    }

    override func set(_ addr: Int64, _ value: Int64) {
      guard addr >= 0, addr < data.count else { return }
      if data[Int(addr)] != value { data[Int(addr)] = value }
    }

    override func clonePage() -> MemContents.Page { LongPage(copying: data) }
  }
}
