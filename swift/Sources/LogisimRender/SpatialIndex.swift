// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Uniform-grid index over scene groups.
//
// A struct with two flat arrays, not a tree: the scene's geometry is immutable once built, so
// the index is built once and never mutated, and schematic components are small and evenly
// spread across the grid; the case a uniform grid is best at and a BVH buys nothing on.
// Staying a value type also keeps `RenderScene` trivially `Sendable`.

// MARK: - SpatialIndex

public struct SpatialIndex: Sendable {
  /// Side of one bucket, in schematic units. Logisim's snap grid is 10 and components run
  /// 20-80 units, so 128 puts a handful of components in a bucket and keeps a full-screen
  /// query to a few hundred bucket visits.
  public static let defaultCellSize: Int32 = 128

  public let cellSize: Int32
  public let originX: Int32
  public let originY: Int32
  public let columns: Int32
  public let rows: Int32

  /// CSR layout: bucket `i` owns `items[cellStart[i] ..< cellStart[i+1]]`.
  private let cellStart: [Int32]
  private let items: [Int32]

  /// Groups too large or too far out to bucket sensibly. Always visited.
  private let oversized: [Int32]

  public init(groups: [SceneGroup], cellSize: Int32 = SpatialIndex.defaultCellSize) {
    let cell = max(1, cellSize)
    self.cellSize = cell

    var world = SceneBounds.empty
    for g in groups where !g.bounds.isEmpty {
      world.formUnion(g.bounds)
    }

    guard !world.isEmpty, !groups.isEmpty else {
      self.originX = 0
      self.originY = 0
      self.columns = 0
      self.rows = 0
      self.cellStart = [0]
      self.items = []
      self.oversized = groups.indices.map { Int32($0) }
      return
    }

    // Cap the grid so a single pathological component at Int32.max does not ask for a
    // billion buckets. Anything that does not fit goes on the oversized list.
    let maxCells = 1 << 20
    var cols = Int((Int64(world.maxX) - Int64(world.minX)) / Int64(cell)) + 1
    var rws = Int((Int64(world.maxY) - Int64(world.minY)) / Int64(cell)) + 1
    cols = max(1, min(cols, maxCells))
    rws = max(1, min(rws, maxCells / cols))

    let ox = world.minX
    let oy = world.minY
    self.originX = ox
    self.originY = oy
    self.columns = Int32(cols)
    self.rows = Int32(rws)

    let cellCount = cols * rws
    var counts = [Int32](repeating: 0, count: cellCount)
    var over: [Int32] = []

    // A group spanning more than this many buckets is cheaper to test directly than to
    // register in every one of them.
    let spanLimit = 64

    func span(_ b: SceneBounds) -> (c0: Int, c1: Int, r0: Int, r1: Int)? {
      if b.isEmpty { return nil }
      // Every group bounds is >= (ox, oy) by construction, so truncating division is safe.
      let c0 = Int((Int64(b.minX) - Int64(ox)) / Int64(cell))
      let c1 = Int((Int64(b.maxX) - Int64(ox)) / Int64(cell))
      let r0 = Int((Int64(b.minY) - Int64(oy)) / Int64(cell))
      let r1 = Int((Int64(b.maxY) - Int64(oy)) / Int64(cell))
      if c1 < 0 || r1 < 0 || c0 >= cols || r0 >= rws { return nil }
      let cc0 = max(0, c0), cc1 = min(cols - 1, c1)
      let rr0 = max(0, r0), rr1 = min(rws - 1, r1)
      if cc0 > cc1 || rr0 > rr1 { return nil }
      if (cc1 - cc0 + 1) * (rr1 - rr0 + 1) > spanLimit { return nil }
      return (cc0, cc1, rr0, rr1)
    }

    for (i, g) in groups.enumerated() {
      guard let s = span(g.bounds) else {
        if !g.bounds.isEmpty { over.append(Int32(i)) }
        continue
      }
      for r in s.r0...s.r1 {
        for c in s.c0...s.c1 {
          counts[r * cols + c] += 1
        }
      }
    }

    var starts = [Int32](repeating: 0, count: cellCount + 1)
    var running: Int32 = 0
    for i in 0..<cellCount {
      starts[i] = running
      running += counts[i]
    }
    starts[cellCount] = running

    var cursor = starts
    var slots = [Int32](repeating: 0, count: Int(running))
    for (i, g) in groups.enumerated() {
      guard let s = span(g.bounds) else { continue }
      for r in s.r0...s.r1 {
        for c in s.c0...s.c1 {
          let idx = r * cols + c
          slots[Int(cursor[idx])] = Int32(i)
          cursor[idx] += 1
        }
      }
    }

    self.cellStart = starts
    self.items = slots
    self.oversized = over
  }

  /// Group indices whose bounds may intersect `rect`, **in ascending order**.
  ///
  /// Ascending order is not cosmetic: it is the painter's order the scene was emitted in, and
  /// a schematic where a filled body is drawn before its label depends on it.
  public func groupsIntersecting(_ rect: SceneBounds, groupCount: Int) -> [Int32] {
    guard groupCount > 0 else { return [] }
    if columns == 0 || rows == 0 || rect.isEmpty {
      return oversized
    }

    var seen = [Bool](repeating: false, count: groupCount)
    var result: [Int32] = []
    result.reserveCapacity(64)

    for g in oversized where !seen[Int(g)] {
      seen[Int(g)] = true
      result.append(g)
    }

    let cols = Int(columns)
    let rws = Int(rows)
    let cell = Int64(cellSize)
    var c0 = Int((Int64(rect.minX) - Int64(originX)) / cell)
    var c1 = Int((Int64(rect.maxX) - Int64(originX)) / cell)
    var r0 = Int((Int64(rect.minY) - Int64(originY)) / cell)
    var r1 = Int((Int64(rect.maxY) - Int64(originY)) / cell)
    // Integer division truncates toward zero, so negative offsets land one bucket high.
    if Int64(rect.minX) - Int64(originX) < 0 { c0 -= 1 }
    if Int64(rect.maxX) - Int64(originX) < 0 { c1 -= 1 }
    if Int64(rect.minY) - Int64(originY) < 0 { r0 -= 1 }
    if Int64(rect.maxY) - Int64(originY) < 0 { r1 -= 1 }

    c0 = max(0, c0); c1 = min(cols - 1, c1)
    r0 = max(0, r0); r1 = min(rws - 1, r1)
    guard c0 <= c1, r0 <= r1 else {
      result.sort()
      return result
    }

    for r in r0...r1 {
      let rowBase = r * cols
      for c in c0...c1 {
        let idx = rowBase + c
        let lo = Int(cellStart[idx])
        let hi = Int(cellStart[idx + 1])
        var k = lo
        while k < hi {
          let g = items[k]
          if !seen[Int(g)] {
            seen[Int(g)] = true
            result.append(g)
          }
          k += 1
        }
      }
    }

    result.sort()
    return result
  }
}
