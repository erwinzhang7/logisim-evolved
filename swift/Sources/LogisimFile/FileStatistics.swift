// logisim-evolved -- a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (com.cburch.logisim.file.FileStatistics),
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// This used to live in `Sources/logisim-cli/StatsRun.swift`, because `-tty stats` was its only
// consumer. The GUI command is the second consumer, and upstream owns the algorithm in the file
// package, not in either front end: `StatisticsDialog.show` and `TtyInterface.displayStatistics`
// both call `FileStatistics.compute(LogisimFile, Circuit)`.
//
// The one place upstream is order-dependent, and it is NOT the printed order:
//
// `FileStatistics.compute` builds `include` as `new HashSet<>(file.getCircuits())` and iterates
// it (`FileStatistics.java:89`). The printed ORDER is safe -- that comes from `sortCounts`, which
// walks `file.getTools()` and then each library's tool list, both of which are ordered lists.
//
// What the hash order can reach is the unique column. Inside `doRecursiveCount`, merging
// subcircuit A's counts can CREATE a `Count` for subcircuit B's factory (with `simpleCount == 0`)
// in the parent's map. If the include-iteration then reaches B, `counts.containsKey(subFactory)`
// is now true, so `doRecursiveCount(B, ...)` runs and B enters `countMap` -- and
// `doUniqueCounts` sums `simpleCount` over `countMap.keySet()`. Reach B before A instead and it
// never enters, so its components are not counted as unique. The recursive and simple columns are
// immune (the multiplier is `simpleCount`, which the merge never mutates, so the sums are
// commutative).
//
// This port iterates `file.circuits`, which is an ordered list, so it is deterministic. Whether
// upstream actually varies on this corpus is measured, not assumed: `statsgate.py --selfcheck`
// runs the jar against itself and reports any case that disagrees with its own earlier output.

import Foundation

/// `com.cburch.logisim.file.FileStatistics`.
public enum FileStatistics {

  /// `FileStatistics.Count`. A class, not a struct: upstream mutates these in place through
  /// several maps that alias the same object, and a value type would silently drop those updates.
  public final class Count {
    /// `null` in Java for the two synthetic totals; `sortCounts` fills it for every listed row.
    public var library: Library?
    public let factory: (any ComponentFactory)?
    public var simpleCount = 0
    public var uniqueCount = 0
    public var recursiveCount = 0

    init(factory: (any ComponentFactory)?) {
      self.factory = factory
    }
  }

  public struct Result {
    public let counts: [Count]
    public let totalWithoutSubcircuits: Count
    public let totalWithSubcircuits: Count
  }

  /// `FileStatistics.compute(LogisimFile, Circuit)`.
  public static func compute(file: LogisimFile, circuit: Circuit) -> Result {
    let include = file.circuits
    let includeIds = Set(include.map(ObjectIdentifier.init))
    var countMap: [ObjectIdentifier: [ObjectIdentifier: Count]] = [:]
    _ = doRecursiveCount(circuit, include, includeIds, &countMap)
    let own = countMap[ObjectIdentifier(circuit)] ?? [:]
    doUniqueCounts(own, countMap)
    let list = sortCounts(own, file)
    return Result(
      counts: list,
      totalWithoutSubcircuits: total(list, excluding: includeIds),
      totalWithSubcircuits: total(list, excluding: nil))
  }

  /// `doRecursiveCount(Circuit, Set<Circuit>, Map<Circuit, Map<ComponentFactory, Count>>)`.
  @discardableResult
  private static func doRecursiveCount(
    _ circuit: Circuit,
    _ include: [Circuit],
    _ includeIds: Set<ObjectIdentifier>,
    _ countMap: inout [ObjectIdentifier: [ObjectIdentifier: Count]]
  ) -> [ObjectIdentifier: Count] {
    let key = ObjectIdentifier(circuit)
    if let existing = countMap[key] { return existing }

    var counts = doSimpleCount(circuit)
    countMap[key] = counts
    for count in counts.values {
      count.uniqueCount = count.simpleCount
      count.recursiveCount = count.simpleCount
    }

    for sub in include {
      let subFactoryId = ObjectIdentifier(sub.subcircuitFactory)
      guard let direct = counts[subFactoryId] else { continue }
      let multiplier = direct.simpleCount
      let subCounts = doRecursiveCount(sub, include, includeIds, &countMap)
      for subCount in subCounts.values {
        guard let subFactory = subCount.factory else { continue }
        let id = ObjectIdentifier(subFactory)
        let superCount: Count
        if let found = counts[id] {
          superCount = found
        } else {
          superCount = Count(factory: subFactory)
          counts[id] = superCount
          // The dictionary is a value type in Swift and a reference in Java, so the map the
          // recursion memoised has to be refreshed or the new `Count` is invisible to the parent
          // on a later pass. Upstream mutates one shared HashMap and needs no equivalent.
          countMap[key] = counts
        }
        superCount.recursiveCount += multiplier * subCount.recursiveCount
      }
    }

    countMap[key] = counts
    return counts
  }

  /// `doSimpleCount(Circuit)`.
  private static func doSimpleCount(_ circuit: Circuit) -> [ObjectIdentifier: Count] {
    var counts: [ObjectIdentifier: Count] = [:]
    for component in circuit.nonWires {
      let factory = component.factory
      let id = ObjectIdentifier(factory)
      let count: Count
      if let found = counts[id] {
        count = found
      } else {
        count = Count(factory: factory)
        counts[id] = count
      }
      count.simpleCount += 1
    }
    return counts
  }

  /// `doUniqueCounts(Map<ComponentFactory, Count>, Map<Circuit, Map<ComponentFactory, Count>>)`.
  private static func doUniqueCounts(
    _ counts: [ObjectIdentifier: Count],
    _ circuitCounts: [ObjectIdentifier: [ObjectIdentifier: Count]]
  ) {
    for count in counts.values {
      guard let factory = count.factory else { continue }
      let id = ObjectIdentifier(factory)
      var unique = 0
      for (_, perCircuit) in circuitCounts {
        if let subcount = perCircuit[id] { unique += subcount.simpleCount }
      }
      count.uniqueCount = unique
    }
  }

  /// `getTotal(List<Count>, Set<Circuit>)`. `excluding == nil` is Java's `exclude == null`,
  /// i.e. the with-subcircuits total.
  private static func total(_ counts: [Count], excluding: Set<ObjectIdentifier>?) -> Count {
    let ret = Count(factory: nil)
    for count in counts {
      var factoryCircuitId: ObjectIdentifier?
      if let sub = count.factory as? any SubcircuitFactory {
        factoryCircuitId = ObjectIdentifier(sub.subcircuit)
      }
      let skip: Bool
      if let excluding {
        // Java: `!exclude.contains(factoryCirc)`; a HashSet never contains null, so a
        // non-subcircuit factory is always counted.
        skip = factoryCircuitId.map(excluding.contains) ?? false
      } else {
        skip = false
      }
      if skip { continue }
      ret.simpleCount += count.simpleCount
      ret.uniqueCount += count.uniqueCount
      ret.recursiveCount += count.recursiveCount
    }
    return ret
  }

  /// `sortCounts(Map<ComponentFactory, Count>, LogisimFile)`.
  ///
  /// This is what makes the printed order deterministic: the file's own tool list first (with
  /// the file itself recorded as the owning "library"), then every library's tool list in
  /// declaration order. A factory present in the circuit but in NO tool list is silently omitted
  /// -- from the listing and from both totals, because the totals are computed over this list.
  /// That is upstream behaviour and it is the reason a D8-preserved unknown component does not
  /// appear in `stats` output.
  private static func sortCounts(
    _ counts: [ObjectIdentifier: Count], _ file: LogisimFile
  ) -> [Count] {
    var ret: [Count] = []
    for tool in file.tools {
      guard let addTool = tool as? AddTool else { continue }
      guard let count = counts[ObjectIdentifier(addTool.factory)] else { continue }
      count.library = file
      ret.append(count)
    }
    for lib in file.libraries {
      for tool in lib.tools {
        guard let addTool = tool as? AddTool else { continue }
        guard let count = counts[ObjectIdentifier(addTool.factory)] else { continue }
        count.library = lib
        ret.append(count)
      }
    }
    return ret
  }
}
