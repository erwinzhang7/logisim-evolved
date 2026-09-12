// JavaHashSetOrder: part of logisim-evolved.
//
// Not a translation of any single upstream file: this reproduces `java.util.HashSet`'s
// *iteration order* so that `Netlist`'s net numbering matches the shipped 4.1.0 jar's.
// GPL-3.0-only with the rest of the port. See LICENSE.md.
//
// ══ WHY THIS EXISTS ═════════════════════════════════════════════════════════════════════════
//
// `Netlist.generateNetlist()` seeds each new `Net` with "whatever wire the iterator hands back
// first" from a `HashSet<Wire>` (`Netlist.java:566-575`, `getNet` at `:1255`). The order in
// which nets are discovered becomes their index in `myNets`, and `getNetId(net)` is that index
// , which is emitted verbatim into the generated HDL as `s_LOGISIM_NET_<id>` /
// `s_LOGISIM_BUS_<id>`. So JVM hash order is not an implementation detail here: it is part of
// the output text. A Swift `Set` iterates in a different, seed-randomised order, which would
// permute every net name in every generated file.
//
// Reproducing it is cheap and exact for this case, because `HashMap`'s final bucket layout is a
// pure function of (the keys' `hashCode()`s, their insertion order, the table capacity):
//
//   * `hash(key) = h ^ (h >>> 16)` where `h = key.hashCode()`  (`HashMap.hash`)
//   * bucket index = `hash & (capacity - 1)`
//   * a bucket is a linked list appended at the tail, so within a bucket, insertion order
//   * `resize()` splits each bucket into a "lo" and a "hi" list *preserving relative order*,
//     so after any number of resizes a bucket still holds its members in insertion order
//   * iteration walks buckets `0 ..< capacity`, each list head-to-tail
//
// Therefore the final order equals: bucket-index sort (stable, by insertion order) at the final
// capacity. Capacity is itself determined by the final size: `new HashSet<>()` starts at 16 and
// doubles whenever `size > capacity * 0.75`.
//
// ── The two simplifications, and why they are safe here ─────────────────────────────────────
//
//  1. **Treeification is not modelled.** `HashMap` converts a bucket to a red-black tree at 8
//     entries *and* capacity >= 64, which reorders that bucket. Reaching it needs 8 wires whose
//     spread hashes collide modulo a >= 64 table; `Wire.hashCode()` is
//     `e0.hashCode() * 31 + e1.hashCode()` over `Location.hashCode() = 31 * x + y`, which is
//     well spread over a circuit's coordinates. `treeifyThreshold` documents the check.
//  2. **Removals are not modelled.** Java's `Netlist.wires` is filled once by `addAll` and then
//     drained by `Iterator.remove()`; removal never changes capacity or the relative order of
//     what remains, so draining an ordered array in place is equivalent.
//
// Both are recorded rather than hidden: `orderedLikeJavaHashSet` is the whole of the emulation,
// and the tests in `LogisimHdlTests` pin it against values taken from a real JVM.

/// `Object.hashCode()` for the handful of types whose JVM hash the netlist order depends on.
///
/// This is *Java's* hash, not Swift's; `Hasher` is seed-randomised per process and cannot be
/// used for anything whose result reaches a file.
public protocol JavaHashable {
  /// The exact 32-bit value `hashCode()` returns on the JVM, widened to `Int`.
  var javaHashCode: Int { get }
}

public enum JavaHashSet {

  /// `HashMap.hash(Object)`: `h ^ (h >>> 16)`, where `>>>` is Java's *unsigned* shift.
  public static func spread(_ hashCode: Int) -> Int {
    let h = Int32(truncatingIfNeeded: hashCode)
    let unsigned = UInt32(bitPattern: h)
    return Int(Int32(bitPattern: unsigned ^ (unsigned >> 16)))
  }

  /// The table capacity a `new HashSet<>()` reaches after `count` additions.
  ///
  /// `HashMap` starts at `DEFAULT_INITIAL_CAPACITY = 16` and doubles inside `putVal` whenever
  /// `++size > threshold`, with `threshold = capacity * DEFAULT_LOAD_FACTOR (0.75f)`.
  public static func capacity(forCount count: Int) -> Int {
    var capacity = 16
    // `threshold` is an int: `(int) (capacity * 0.75f)`, exact for every power of two here.
    while count > (capacity / 4) * 3 { capacity <<= 1 }
    return capacity
  }

  /// Bucket size at which `HashMap` would switch to a red-black tree; see the header. Exposed
  /// so a caller (or a test) can assert it was never reached rather than silently diverge.
  public static let treeifyThreshold = 8

  /// The order `java.util.HashSet` would iterate `elements` in, given that they were added in
  /// the order supplied.
  ///
  /// Duplicates are *not* removed: pass a de-duplicated sequence, exactly as `Set` semantics
  /// would already have done.
  public static func order<T>(_ elements: [T], hashCode: (T) -> Int) -> [T] {
    guard elements.count > 1 else { return elements }
    let cap = capacity(forCount: elements.count)
    var buckets = [[T]](repeating: [], count: cap)
    for element in elements {
      let index = spread(hashCode(element)) & (cap - 1)
      buckets[index].append(element)
    }
    var result: [T] = []
    result.reserveCapacity(elements.count)
    for bucket in buckets { result.append(contentsOf: bucket) }
    return result
  }

  /// Whether any bucket reached `treeifyThreshold` at a capacity of 64 or more; i.e. whether
  /// this emulation is known-inexact for the given input. Diagnostic only.
  public static func wouldTreeify<T>(_ elements: [T], hashCode: (T) -> Int) -> Bool {
    let cap = capacity(forCount: elements.count)
    guard cap >= 64 else { return false }
    var counts = [Int](repeating: 0, count: cap)
    for element in elements {
      counts[spread(hashCode(element)) & (cap - 1)] += 1
    }
    return counts.contains { $0 >= treeifyThreshold }
  }
}

extension JavaHashSet {
  /// Convenience overload for elements that know their own JVM hash.
  public static func order<T: JavaHashable>(_ elements: [T]) -> [T] {
    order(elements) { $0.javaHashCode }
  }
}
